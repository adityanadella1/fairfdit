# FairEdit AI backend.
#
# Two stages so the ~6 GB CUDA toolchain needed to build Grounding DINO's
# CUDA extension does not ship in the runtime image.

# ---------------------------------------------------------------------
# Builder
# ---------------------------------------------------------------------
FROM nvidia/cuda:12.1.1-devel-ubuntu22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3.11 python3.11-dev python3-pip git build-essential ninja-build \
    && rm -rf /var/lib/apt/lists/*

# Grounding DINO compiles a CUDA extension at install time and needs to
# know which architectures to target. Ampere through Ada covers current
# datacentre and workstation GPUs; add your own if deploying elsewhere.
ENV TORCH_CUDA_ARCH_LIST="8.0;8.6;8.9;9.0" \
    CUDA_HOME=/usr/local/cuda \
    FORCE_CUDA=1

WORKDIR /build
RUN python3.11 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

RUN pip install --upgrade pip setuptools wheel

# torch first and on its own layer: it is the largest dependency and the
# one least likely to change, so it stays cached across rebuilds.
RUN pip install torch==2.5.1 torchvision==0.20.1 \
        --index-url https://download.pytorch.org/whl/cu121

COPY requirements.txt .
RUN pip install -r requirements.txt

# Upstream inference code. fetch_vendor.py pip-installs SAM 2 and
# Grounding DINO and extracts LaMa's inference subset into vendor/ —
# see that script for exactly what is and is not taken.
COPY scripts/fetch_vendor.py scripts/
RUN python scripts/fetch_vendor.py

# ---------------------------------------------------------------------
# Runtime
# ---------------------------------------------------------------------
FROM nvidia/cuda:12.1.1-runtime-ubuntu22.04 AS runtime

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH"

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3.11 libgl1 libglib2.0-0 curl \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 1000 fairedit

COPY --from=builder /opt/venv /opt/venv
COPY --from=builder /build/vendor /app/vendor

WORKDIR /app
COPY --chown=fairedit:fairedit app ./app
COPY --chown=fairedit:fairedit scripts ./scripts

# Weights are mounted, not baked: ~2 GB that would otherwise be pushed
# and pulled on every code change.
ENV FAIREDIT_WEIGHTS_DIR=/weights \
    FAIREDIT_VENDOR_DIR=/app/vendor \
    FAIREDIT_LAMA_DIR=/weights/big-lama \
    FAIREDIT_GROUNDING_CHECKPOINT=/weights/groundingdino_swint_ogc.pth
RUN mkdir -p /weights && chown fairedit:fairedit /weights

USER fairedit
EXPOSE 8000

# Probes /v1/ready rather than /v1/health: a deployment missing one
# optional checkpoint is degraded, not unhealthy, and should not be
# restarted in a loop over it.
HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 \
    CMD curl -fsS http://localhost:8000/v1/ready || exit 1

# One worker. The models are the memory cost and they do not share across
# processes, so scaling means more containers on more GPUs, not more
# workers on one.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
