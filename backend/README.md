# FairEdit AI Backend

AI masking and object removal for the FairEdit photo editor. Three
upstream models behind one HTTP contract:

| Capability | Pipeline |
|---|---|
| Select Subject | SAM 2 (detector-hinted, automatic fallback) → rank → refine |
| Select Person | Grounding DINO `"person"` → boxes → SAM 2 → union |
| Select Object | Grounding DINO `"<prompt>"` → boxes → SAM 2 → union |
| Select Sky | Grounding DINO `"sky"` → boxes → SAM 2 → largest region |
| Select Background | Select Subject → invert |
| AI Remove | mask → dilate → LaMa → composite |

## What is and is not in this repository

No upstream repository is vendored wholesale.

- **SAM 2** and **Grounding DINO** publish installable packages. They are
  installed from git as dependencies — `scripts/fetch_vendor.py` runs the
  pip install and copies nothing but Grounding DINO's model config file,
  which `load_model()` needs as a filesystem path.
- **LaMa** has no package, so the same script extracts the inference
  subset of `saicinpainting/` into `vendor/` under an explicit allowlist.
  Training loops, dataset code, loss networks, evaluation harnesses,
  notebooks and demos are excluded by name and the script reports how
  many files it left behind.

Run `python scripts/fetch_vendor.py --dry-run` to see the plan before it
touches anything.

## Setup

> **Use Python 3.11.** LaMa is a 2021 codebase whose import closure
> ends at `albumentations <1.0` -> `imgaug` -> `numpy <2.0`, and numpy
> <2 cannot coexist with torch 2.x / OpenCV 5 on Python 3.12+. Both
> Dockerfiles pin `python:3.11-slim` for this reason. SAM 2 and
> Grounding DINO have no such constraint — only AI Remove does, so a
> newer interpreter still gets you Select Subject and Select
> Background.

```bash
cd backend
python -m venv .venv && source .venv/bin/activate   # Windows: .venv\Scripts\activate

# torch first — the right wheel depends on your CUDA version
pip install torch torchvision --index-url https://download.pytorch.org/whl/cu121

pip install -r requirements.txt
python scripts/fetch_vendor.py        # upstream inference code
python scripts/download_weights.py    # ~2 GB of checkpoints

cp .env.example .env
uvicorn app.main:app --reload --port 8000
```

Open http://localhost:8000/docs for the generated OpenAPI reference, or
http://localhost:8000/v1/health to see which engines this machine can
actually serve.

### Docker

```bash
docker compose run --rm weights     # one-time, populates the volume
docker compose up --build
```

Needs the NVIDIA container toolkit.

**No GPU?** There is a dedicated CPU image:

```bash
docker compose --profile cpu up --build api-cpu
```

It drops the CUDA runtime and Grounding DINO (which compiles a CUDA
extension), giving a ~1.5 GB image instead of ~9 GB. `/v1/health` reports
`degraded` and the Flutter client greys out the text-prompted mask types;
**Select Subject, Select Background and AI Remove still work.** Expect
tens of seconds per request — enough to verify the wiring end to end, not
enough for real use.

## Connecting the Flutter app

```bash
flutter run --dart-define=FAIREDIT_AI_BASE_URL=http://10.0.2.2:8000
```

`10.0.2.2` is the Android emulator's alias for the host loopback and is
the default. On a physical device use your machine's LAN address. If an
API key is set, pass `--dart-define=FAIREDIT_AI_API_KEY=...` too.

The app polls `/v1/health` and greys out AI features when it cannot reach
the server, so a missing backend degrades the editor rather than breaking
it.

## API

### `POST /v1/segment`

```jsonc
{
  "mode": "object",        // subject | person | object | background | sky
  "image": "<base64>",
  "prompt": "dog",         // required for mode=object
  "refine_edges": true,
  "grow": 0,               // -50..50 pixels
  "feather": 0.0           // 0..50 pixels
}
```

```jsonc
{
  "mask": "<base64 PNG>",  // 8-bit greyscale, 255 = fully selected
  "width": 3024, "height": 4032,
  "score": 0.94,           // model confidence
  "coverage": 0.18,        // fraction of frame selected
  "box": [0.31, 0.12, 0.78, 0.94],
  "mode": "object", "prompt": "dog",
  "source": "object:dog|refine_edges",
  "elapsed_ms": 1180
}
```

The mask comes back at the dimensions of the image you sent, whatever
resolution inference ran at.

### `POST /v1/remove`

```jsonc
{ "image": "<base64>", "mask": "<base64>", "dilate": 8 }
```

```jsonc
{ "image": "<base64 PNG>", "width": 3024, "height": 4032, "elapsed_ms": 4210 }
```

### `GET /v1/health`

Engine status, servable capabilities, device info and queue depth.
Unauthenticated and cheap — it never loads a model.

### Status codes

| Code | Meaning |
|---|---|
| 400 | Malformed image, mask or prompt |
| 401 | Missing or wrong `X-API-Key` (only when one is configured) |
| 404 | Ran correctly, found nothing — *not* an error |
| 422 | Schema violation |
| 503 | Engine unavailable on this deployment, or queue saturated |
| 504 | Inference exceeded its budget |

404 is the one worth noting: "there is no dog in this photo" is a real
answer, and the client renders it as a sentence rather than as an error.

## Tests

```bash
pytest                        # contract, mask algebra, image I/O
pytest tests/test_mask_engine.py -v
```

These run without weights, a GPU, a network — or even torch installed.
The engines defer every torch import into the methods that use it, so the
service boots, serves `/v1/health` and reports every engine as
unconfigured on a machine that has none of them. That is what makes the
contract testable in a plain CI container.

What they cover is the part that breaks silently during a refactor:
validation, routing, auth, error mapping, and the mask operations every
pipeline depends on. Model quality is a judgement call on real photos,
not an assertion — it is not attempted here.

## Configuration

Every setting is an environment variable prefixed `FAIREDIT_`; see
`.env.example` for the annotated list. The ones that matter in production:

| Variable | Why |
|---|---|
| `FAIREDIT_API_KEY` | **Set this before exposing the port.** Without it, anyone who can reach the service can spend your GPU. |
| `FAIREDIT_GPU_WORKERS` | Keep at 1 per physical GPU. Two concurrent forward passes on one device contend for VRAM and finish slower than if they had queued. |
| `FAIREDIT_EAGER_LOAD` | `true` behind a health-checked load balancer: ~30s slower boot, predictable first request. |
| `FAIREDIT_MAX_INFERENCE_DIMENSION` | Segmentation quality saturates well below 4K; the attention cost does not. |

## Layout

```
app/
├── api/          routes, dependencies, error→status mapping
├── schemas/      request/response contracts (pydantic)
├── services/     decode, resolution management, pipeline routing
├── pipelines/    engine composition — one per capability
├── engines/      the only code that touches SAM 2 / DINO / LaMa
├── workers/      bounded GPU executor
└── utils/        image I/O, device selection
```

The rule the structure enforces: **no route imports upstream code.** A
route calls a service, a service runs a pipeline on the GPU pool, a
pipeline composes engines, and an engine is the single place that knows
what `sam2` or `saicinpainting` looks like. Swapping SAM 2 for something
newer touches one file.
