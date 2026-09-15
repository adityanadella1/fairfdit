# vendor/

Populated by `python ../scripts/fetch_vendor.py`. **Not checked in** —
this directory holds extracted upstream code, and the script is the
record of what comes from where.

## What lands here

### `saicinpainting/` — from [advimman/lama](https://github.com/advimman/lama)

LaMa publishes no installable package, so the inference subset of its
source is extracted here under an explicit allowlist:

```
saicinpainting/
├── __init__.py
├── utils.py
├── training/          model definitions + load_checkpoint
└── evaluation/
    ├── utils.py
    ├── data.py
    └── refinement.py
```

`training/` is where LaMa puts its *network definitions*, which is why it
is kept despite the name — `load_checkpoint` lives in
`training/trainers/` and is what constructs the network at inference
time.

Excluded by name: `losses/`, `visualizers/`, the training dataloader
package, `bin/`, notebooks, benchmarks, experiment configs. The engine
loads its checkpoint with `strict=False` precisely so the loss-network
weights those modules would need can be dropped.

`app/main.py` puts this directory on `sys.path` at startup. That is the
only path manipulation in the service.

### `groundingdino/config/` — from [IDEA-Research/GroundingDINO](https://github.com/IDEA-Research/GroundingDINO)

One file: `GroundingDINO_SwinT_OGC.py`. The package itself is pip-
installed; only this config is copied, because `load_model()` takes a
filesystem path rather than a module reference.

## What does *not* land here

**SAM 2** — installed as a package (`pip install git+…`). Nothing copied.

**Grounding DINO** — same, apart from the one config file above.

Reuse through a package is better than reuse through a copy: upstream
fixes arrive with a version bump instead of a re-extraction, and there is
no forked source to drift.

## Auditing

```bash
python scripts/fetch_vendor.py --dry-run    # show the plan
python scripts/fetch_vendor.py -v           # log every file copied
```

The script reports how many files it copied and how many it left
upstream, so the allowlist is verifiable rather than assumed.
