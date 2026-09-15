# FairEdit AI — Architecture

How three research repositories become one production service, and why
each boundary is where it is.

---

## Phase 1 — Repository analysis

The governing rule: **extract the import closure of a forward pass,
nothing else.** For each project, that means starting from the entry
point the engine actually calls and keeping only what it reaches.

### SAM 2 — `facebookresearch/sam2`

Publishes an installable package, so it is a dependency, not a copy.

**Entry points used** (`app/engines/sam2_engine.py`):

| Import | Used for |
|---|---|
| `sam2.build_sam.build_sam2` | Model construction from a local checkpoint |
| `sam2.sam2_image_predictor.SAM2ImagePredictor` | Box- and point-prompted segmentation |
| `sam2.automatic_mask_generator.SAM2AutomaticMaskGenerator` | Unprompted segmentation for the Select Subject fallback |

`modeling/` and `utils/` come along as transitive dependencies of those
three — they are the network definition and the pre/post-processing the
predictor calls.

**Not used:** `notebooks/`, `demo/`, `training/`, `tools/`, video
predictor and SA-V dataset code, benchmark scripts.

Two construction paths are supported. A local checkpoint plus a hydra
config name is the deterministic one and what the Docker image uses; the
Hugging Face id (`SAM2ImagePredictor.from_pretrained`) downloads on first
use and is the convenient one for development. `apply_postprocessing` is
turned **off** — SAM's own hole-filling would round off small genuine
gaps before `MaskEngine` ever sees them, and `MaskEngine` does that step
under the pipeline's control.

### Grounding DINO — `IDEA-Research/GroundingDINO`

Also pip-installable. One file is copied:
`groundingdino/config/GroundingDINO_SwinT_OGC.py`, because `load_model()`
takes a filesystem path to a config rather than a module reference.

**Entry points used** (`app/engines/grounding_engine.py`):

| Import | Used for |
|---|---|
| `groundingdino.util.inference.load_model` | Build from config + checkpoint |
| `groundingdino.util.inference.predict` | Text-prompted detection |
| `groundingdino.datasets.transforms` | The exact preprocessing the released weights expect |

That last one matters more than it looks. The released weights assume
resize-shortest-side-to-800 with a 1333 cap, then ImageNet
normalisation. Reimplementing that and getting a detail wrong does not
error — detection just quietly gets worse, which is the hardest class of
bug to find. So the repository's own transform is used verbatim.

Two other details are handled in the engine rather than left to callers:
captions are normalised to lower case and period-terminated (upstream
separates phrases with periods, and a caption without one detects
measurably worse), and boxes are converted from the model's native
centre-width-height form to normalised corners, clamped to the frame.

**Not used:** `train/`, `evaluation/`, COCO tooling, dataset generation,
`demo/`, research scripts.

### LaMa — `advimman/lama`

No package exists, so this is the one project with extracted source, in
`vendor/` under an allowlist.

**Kept:**

```
saicinpainting/
├── __init__.py
├── utils.py
├── training/          ← model definitions live here, not just the trainer
└── evaluation/
    ├── utils.py
    ├── data.py        ← padding helpers
    └── refinement.py
```

`training/` is counterintuitive but correct: LaMa puts its *network
definitions* under `training/modules/`, and `load_checkpoint` is in
`training/trainers/`. The trainer module is what constructs the network,
even at inference time.

**Excluded by name:** `losses/` and `visualizers/` (training-only — the
engine loads with `strict=False` precisely so the VGG perceptual net and
discriminator weights in the checkpoint can be dropped), the training
dataloader package, `bin/`, `configs/` for training, notebooks,
benchmarks.

Three config overrides turn the released training config into an
inference config: `predict_only = True`, `visualizer.kind = "noop"`, and
dropping `losses`. Without them the trainer tries to build optimisers,
loggers and a visualiser at construction time.

**The allowlist here is short on purpose, and that was learned the hard
way.** Three successive attempts to carve LaMa up by directory name each
moved the failure one import further down the chain:

| Excluded because it "looked like training" | Actually imported by |
|---|---|
| `saicinpainting/training/` | it holds the *model definitions* |
| `training/data/` | `trainers/base.py`, at module scope |
| `evaluation/losses/` | the evaluator — they are metrics, not losses |
| `models/` (repo root) | those metrics, for an ade20k network |

`trainers/base.py` does `from saicinpainting.evaluation import
make_evaluator` at module scope, so importing `load_checkpoint` at all
drags in the entire metrics stack. The honest boundary is "the
`saicinpainting` package plus `models/`, minus what is unambiguously
training-only" — around 79 files. A narrower allowlist is not smaller in
practice, just more fragile.

The import closure is now derived by *running the import*, not by
reading directory names, and `fetch_vendor.py` raises if an allowlist
entry matches nothing rather than reporting success on a partial
extraction.

**Consequence: LaMa constrains the interpreter.** That closure bottoms
out at `albumentations <1.0` -> `imgaug` -> `numpy <2.0`, which is
incompatible with torch 2.x and OpenCV 5 on Python 3.12+. Both
Dockerfiles pin `python:3.11-slim`. SAM 2 and Grounding DINO are
unaffected — only AI Remove carries this constraint.

### Enforcement

`scripts/fetch_vendor.py` encodes all of the above as data — a `Recipe`
per project with an `include` list and an `exclude_names` set, plus a
`GLOBAL_EXCLUDES` set applied to all three. It prints how many files it
copied and how many it left upstream, so the allowlist is auditable
rather than aspirational. `--dry-run` shows the plan without touching
anything.

---

## Phase 2 — Architecture

### Layers

```
HTTP        api/            routes, auth, error→status mapping
contract    schemas/        pydantic request/response models
orchestration services/     decode, resolution management, routing
composition pipelines/      one per user-facing capability
integration engines/        the ONLY code that imports upstream
execution   workers/        bounded GPU executor
primitives  utils/          image I/O, device selection
```

**The invariant: no route imports upstream code.** A route calls a
service; a service submits a pipeline to the GPU pool; a pipeline
composes engines; an engine is the single place that knows what `sam2`
or `saicinpainting` looks like.

The payoff is concrete. Replacing SAM 2 with a successor touches
`sam2_engine.py` and nothing else. Adding a dedicated sky model means
rewriting the body of `SelectSkyPipeline` — the API, the client and every
other pipeline are unaffected, because the boundary between them is a
`Mask`, not a method.

### MaskEngine — the shared representation

Four sources produce something mask-shaped in four different formats:
SAM 2 (bool arrays, sometimes batched), Grounding DINO (boxes),
the client's brush tool (PNG), and a future sky model. All four are
normalised into one type on arrival:

> **A mask is HW `float32` in 0..1.** Soft, never binary.

Soft matters: feathering and partial coverage are the entire point of a
mask that drives an exposure slider, and quantising to `bool` throws that
away. `MaskEngine.from_array` handles the format normalisation —
including squeezing the singleton batch axis SAM 2 returns for a single
prompt.

The Flutter shader carries **six** mask slots (`MaskingState.maxSlots`,
mirrored by the `uMask0..5` uniform block in `edit_shader.frag`). Each
slot costs eleven float uniforms and one texture sampler, so the ceiling
is the fragment stage's sampler budget — eleven in use against a
guaranteed sixteen. The two constants must move together: raising the
Dart one alone writes past the end of the uniform block.

Coverage for a texture-backed slot is sampled at the *call site* and
passed in as a float, rather than the slot function taking a `sampler2D`.
SkSL rejects sampler parameters outright ("parameters of type 'shader'
not allowed"), so the earlier signature compiled only under Impeller.

Every operation is a classmethod returning a **new** mask. Masks flow
between pipeline stages and get cached; an in-place edit to a shared
array is exactly the kind of bug that appears once in production and
never in a test.

| Group | Operations |
|---|---|
| Construction | `create` · `from_array` · `from_box` |
| Algebra | `add` · `subtract` · `intersect` · `invert` · `union_all` |
| Morphology | `expand` · `contract` · `feather` · `smooth` · `fill_holes` · `remove_holes` · `keep_largest_component` |
| Refinement | `refine_edges` |
| Geometry | `resize` · `bounding_box` |
| Wire | `serialize` · `to_png_base64` |

Two choices worth their reasoning:

- `add` is **max**, not sum — two overlapping soft masks must not clip to
  a hard edge where they meet.
- `intersect` is **product**, not min — two 50% soft regions intersect to
  25%, the probabilistic reading, which is what a feathered edge means.

`refine_edges` uses a guided filter over the source image. SAM 2's masks
are excellent but decoded at 256×256 and upsampled, so the boundary sits
a pixel or two off on hair, fur and foliage. Re-deriving the edge from
the image's own gradients fixes most of that visible gap for far less
than a matting network costs, and degrades gracefully to feather+smooth
when `cv2.ximgproc` is unavailable.

### Dependency map

```
                 ┌─────────────┐
    /v1/segment ─┤ Segmentation├─┐
                 │   Service   │ │
                 └─────────────┘ │      ┌──────────┐
                                 ├──────┤ GpuPool  │ (1 job / GPU)
                 ┌─────────────┐ │      └──────────┘
    /v1/remove  ─┤   Inpaint   │─┘            │
                 │   Service   │              ▼
                 └─────────────┘        ┌──────────┐
                                        │ Pipeline │
                                        └────┬─────┘
                          ┌──────────────────┼──────────────────┐
                          ▼                  ▼                  ▼
                  ┌───────────────┐  ┌──────────────┐  ┌──────────────┐
                  │ GroundingEngine│  │  Sam2Engine  │  │  LamaEngine  │
                  └───────┬───────┘  └──────┬───────┘  └──────┬───────┘
                          │                 │                 │
                     groundingdino         sam2         vendor/saicinpainting
                          └─────────────────┼─────────────────┘
                                            ▼
                                      ┌───────────┐
                                      │ MaskEngine│  (every mask, one type)
                                      └───────────┘
```

### Engine lifecycle

Engines are lazy by default: loading is deferred to first use, so the
service starts in seconds and a node that only serves `/v1/remove` never
pays for SAM 2's weights. `FAIREDIT_EAGER_LOAD=true` flips this for
deployments that prefer a slow boot and a fast first request.

Loading is guarded by a lock, not just a `None` check — two requests
arriving together on a cold engine would otherwise both load the weights,
doubling peak VRAM at the worst possible moment. A load failure is cached
and re-raised rather than retried: missing weights will still be missing
next request, and retrying a 30-second load on every call turns a
misconfiguration into an outage.

### GPU execution

FastAPI serves concurrently on an event loop; the models are synchronous,
GPU-bound torch. Running them on the loop blocks health checks. Running
them on the default threadpool lets several forward passes hit one GPU at
once — which is *slower*, not faster, and sometimes OOMs.

So: one `ThreadPoolExecutor` sized to the GPU count, with an explicit
queue depth (`GpuBusy` → 503 + `Retry-After`) and wall-clock timeout
(`GpuTimeout` → 504). Both beat an open-ended wait: the mobile client has
its own timeout, and a request the user already gave up on should not
keep holding the GPU.

---

## Phase 3 — Integration

### Pipelines

Each pipeline is engine composition plus the domain judgement about what
makes a *good* selection.

**Select Subject** tries the detector first, over an ordered noun list
(`person`, `animal`, `car`, `product`). A detected box is a far stronger
SAM prompt than a point grid, and "the main subject" is almost always one
of those. First hit wins, so a photo with a person and a dog selects the
person — which is what "the subject" means in a portrait. Only with no
detection does it fall back to automatic mask generation plus ranking:

```
0.40 × model confidence
0.35 × size score      (peaks near 25% of frame; penalises specks and whole-frame)
0.25 × centrality      (photographers centre subjects far more often than not)
```

No single signal is sufficient, which is why there are three.

**Select Person / Object / Sky** share one implementation
(`GroundedSelectionPipeline`) and differ only in where the noun comes
from — three thin subclasses instead of three copies. If the detector is
confident but SAM returns nothing, they fall back to a box-shaped mask:
crude, but a real selection the user can refine beats an error.

**Select Background** is `invert(Select Subject)`, deliberately — any
improvement to subject detection improves it for free, and the two can
never disagree about where the boundary is. Note the ordering: edge
refinement and grow/feather are applied to the *subject* before
inverting, so `grow: +4` grows the subject and the background shrinks to
match. Inverting first would grow the background *into* the subject.

**AI Remove** is thin, because LaMa does the work. What lives there is
the input hygiene that decides whether the result looks like a removal or
a smudge:

- **Dilate before inpainting.** A mask tracing an object exactly leaves
  its shadow and colour fringe behind, and the network happily
  reconstructs the object *from* them.
- **Fill holes.** A brush stroke with gaps leaves islands of the original
  object, which LaMa treats as context.
- **Cap coverage at 60%.** Past that it is image generation, not
  background reconstruction, and the result is mush. Better a sentence
  than a ruined photo.
- **Composite through a feathered mask.** LaMa regenerates the whole
  frame and its reconstruction of the untouched 95% is slightly softer
  than the source; compositing confines the edit to what was brushed,
  with no seam.
- **Downscale to 1024 for the pass.** LaMa's receptive field is tied to
  its training scale — run native on 4K and the fill is visibly blurry.

### Post-processing order

Fixed, and the order is the one a retoucher would use:

```
remove specks → fill interior gaps → refine edges → grow → feather
```

The user's own grow/feather comes **last** so a later morphological step
cannot undo their adjustment.

### Flutter integration

The client change is smaller than it looks, because an AI mask is just a
texture — which is what the brush mask already was.

- `MaskShapeType` gains `ai`, mapping to the same shader texture slot as
  `brush`. By the time the shader runs, a mask is coverage; what produced
  it is irrelevant to rendering and relevant only to how it gets
  refreshed.
- `MaskSlot` gains `aiMode`, `aiPrompt`, `aiPending` and `enabled`.
- `AiService` is the only class that knows the wire format. The provider
  talks in `ui.Image` and `AiMaskMode`; base64, multipart and status
  codes stop at that boundary.
- Masks are uploaded and stored in **raw-image space**, pre-crop, so they
  survive later crop/rotate/flip edits — the same invariant the
  hand-painted brush textures already hold.
- `AiMaskMode` string values are the wire contract with the backend's
  `SegmentMode`. A contract test asserts the two sets match, because
  renaming one silently breaks every saved project referencing it.

Availability is polled, cached for 30s, and never throws — an unreachable
backend is an expected state (offline, backend not started), so AI
affordances grey out and the editor keeps working. AI Remove falls back
to the on-device diffusion heal if the server drops mid-request, rather
than losing the user's stroke.

---

## Phase 4 — API, testing, deployment

### API contract

See `README.md` for full request/response shapes. The status code policy
is the part worth restating:

| Code | Meaning | Client behaviour |
|---|---|---|
| 400 | Malformed input | Fix and retry |
| 401 | Bad/missing API key | Configuration problem |
| 404 | **Ran fine, found nothing** | Show as a sentence, not an error |
| 422 | Schema violation | Bug in the client |
| 503 | Engine unavailable or queue full | Grey out, or back off on `Retry-After` |
| 504 | Inference overran | Offer retry |

404 earns its own row. "There is no dog in this photo" is a correct
answer from a correctly-functioning pipeline, and conflating it with 500
would put an error dialog in front of a user who simply typed the wrong
noun.

`GET /v1/health` reports per-engine status and a `capabilities` list, so
the client discovers what a deployment can do rather than probing for it.
It returns 200 with `"degraded"` when an engine is missing — a
deployment without LaMa is serving selections correctly, and returning an
error status would pull it out of a load balancer over a partial gap.

### Testing strategy

Three layers, split by what can actually be verified:

**1. Unit — `test_mask_engine.py`, `test_image_io.py`.** No GPU, no
weights, no network. Covers the mask algebra every pipeline depends on
(including that morphology never mutates its input, and that provenance
survives it) and the input-validation boundary.

**2. Contract — `test_api_contract.py`.** Full app with engines stubbed
and the GPU pool executing inline. Runs with **torch not installed** —
every torch import is deferred into the method that uses it, so importing
the API to check its contract does not drag in a multi-gigabyte
dependency, and `/v1/health` can honestly report "unconfigured" on a
machine with no models at all. Covers validation, routing, auth,
error mapping, and that a mask returns at the *requested* dimensions
whatever resolution inference used. Includes an explicit test that
`SegmentMode` matches the Flutter enum.

**3. Model quality — not automated.** Segmentation quality is a
judgement call on a held-out set of real photos, not an assertion. It is
checked by eye before a model or threshold change ships. Pretending
otherwise with a brittle IoU threshold would produce a test that fails
for the wrong reasons.

The Flutter side has its own tests for `LrSlider`'s relative-drag and
double-tap-reset behaviour — both easy to break in a refactor and
invisible in a static widget tree.

```bash
pytest                 # backend
cd ../fairedit && flutter test && flutter analyze
```

### Deployment

Two-stage Docker build: the ~6 GB CUDA *devel* toolchain needed to
compile Grounding DINO's CUDA extension stays in the builder and does not
ship. `TORCH_CUDA_ARCH_LIST` targets Ampere → Hopper; extend it for other
hardware.

Weights are **mounted, not baked** — ~2 GB that would otherwise be pushed
and pulled on every code change. `docker compose run --rm weights`
populates the named volume once.

Scaling is horizontal: one worker per container, one container per GPU.
The models are the memory cost and they do not share across processes, so
more uvicorn workers on one GPU multiplies VRAM without adding
throughput.

The healthcheck probes `/v1/ready`, not `/v1/health`, so a deployment
missing one optional checkpoint is not restarted in a loop over it.

**Before exposing the port:** set `FAIREDIT_API_KEY`. Without it, anyone
who can reach the service can spend your GPU. The check is constant-time,
so a wrong key cannot be recovered a byte at a time from response
latency.

### Known limits

- Sky selection routes through Grounding DINO today. It handles ordinary
  skylines well and struggles with branches, reflections and thin gaps
  between buildings. A dedicated sky model drops into
  `SelectSkyPipeline` without touching anything else.
- Masks are computed in raw-image space and resampled client-side for
  display. A very aggressive crop therefore shows a mask at reduced
  effective resolution — re-running the selection after cropping is the
  workaround, and the reason each AI mask row has its own re-run button.
- Sky selection and the text-prompted modes need Grounding DINO, which
  compiles a CUDA extension. On CPU-only deployments they are
  unavailable and the client greys them out; Select Subject, Select
  Background and AI Remove are unaffected.
- People selection unions everyone in the frame into one mask. Lightroom
  offers per-person selection with body parts (face, hair, clothes),
  which would need a parsing model rather than a detector.
