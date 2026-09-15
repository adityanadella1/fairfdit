"""Runtime configuration.

Everything that differs between a laptop, a CI box and a GPU server lives
here and nowhere else, so no engine ever reads an environment variable
directly. Values come from the environment or a `.env` file; see
`.env.example` for the full set.
"""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path
from typing import Literal

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

BACKEND_ROOT = Path(__file__).resolve().parent.parent


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_prefix="FAIREDIT_",
        extra="ignore",
    )

    # --- Service ------------------------------------------------------
    app_name: str = "FairEdit AI"
    version: str = "1.0.0"
    log_level: str = "INFO"
    log_json: bool = False

    #: Optional shared secret. When set, every /v1 route requires a
    #: matching X-API-Key header. Left empty the service is open, which is
    #: fine on a private network and never fine on a public one.
    api_key: str = ""

    #: Browser origins allowed to call the API. Flutter mobile clients are
    #: not subject to CORS; this exists for a web build.
    cors_origins: list[str] = Field(default_factory=list)

    # --- Compute ------------------------------------------------------
    device: Literal["auto", "cuda", "mps", "cpu"] = "auto"

    #: Half precision on CUDA roughly halves both latency and VRAM. Turned
    #: off automatically on CPU, where float16 is slower, not faster.
    use_fp16: bool = True

    #: Load every model at startup instead of on first use. Costs ~30s of
    #: boot time and buys a predictable first request — the right trade
    #: behind a load balancer that health-checks before sending traffic.
    eager_load: bool = False

    #: Serialised GPU access. One worker is correct for a single GPU: two
    #: concurrent forward passes on one device contend for VRAM and finish
    #: slower than if they had queued.
    gpu_workers: int = 1

    #: Requests rejected once this many are already waiting, so a burst
    #: fails fast instead of timing out client-side after 60s of queueing.
    max_queue_depth: int = 16

    #: Per-inference wall-clock ceiling. A wedged CUDA kernel must not hold
    #: the single GPU worker forever.
    inference_timeout_s: float = 120.0

    # --- Limits -------------------------------------------------------
    #: Largest upload accepted, in megabytes.
    max_upload_mb: float = 25.0

    #: Longest edge the pipelines work at. Above this the image is
    #: downscaled for inference and the resulting mask is scaled back up —
    #: segmentation quality saturates well before 4K.
    max_inference_dimension: int = 1536

    # --- Model locations ----------------------------------------------
    weights_dir: Path = BACKEND_ROOT / "weights"
    vendor_dir: Path = BACKEND_ROOT / "vendor"

    #: SAM 2. Either a Hugging Face id (downloaded and cached on first
    #: use) or a local checkpoint plus its hydra config name.
    sam2_hf_id: str = "facebook/sam2.1-hiera-large"
    sam2_checkpoint: Path | None = None
    sam2_config: str = "configs/sam2.1/sam2.1_hiera_large.yaml"

    # --- Grounding DINO -----------------------------------------------
    grounding_config: Path | None = None
    grounding_checkpoint: Path | None = None
    grounding_box_threshold: float = 0.30
    grounding_text_threshold: float = 0.25

    # --- LaMa ----------------------------------------------------------
    lama_dir: Path | None = None  # directory holding config.yaml + models/
    lama_checkpoint_name: str = "best.ckpt"

    #: LaMa's receptive field assumes a certain scale; running it on a 4K
    #: image directly produces blurry fills. 1024 is the size the released
    #: weights were trained around.
    lama_max_dimension: int = 1024

    @field_validator("cors_origins", mode="before")
    @classmethod
    def _split_origins(cls, v: object) -> object:
        """Accept a comma-separated string, since that is what an
        environment variable can actually carry."""
        if isinstance(v, str):
            return [o.strip() for o in v.split(",") if o.strip()]
        return v

    @property
    def max_upload_bytes(self) -> int:
        return int(self.max_upload_mb * 1024 * 1024)

    def resolved_sam2_checkpoint(self) -> Path | None:
        if self.sam2_checkpoint is not None:
            return self.sam2_checkpoint
        default = self.weights_dir / "sam2.1_hiera_large.pt"
        return default if default.exists() else None

    def resolved_grounding_paths(self) -> tuple[Path | None, Path | None]:
        config = self.grounding_config or (
            self.vendor_dir / "groundingdino" / "config" / "GroundingDINO_SwinT_OGC.py"
        )
        weights = self.grounding_checkpoint or (
            self.weights_dir / "groundingdino_swint_ogc.pth"
        )
        return (
            config if config.exists() else None,
            weights if weights.exists() else None,
        )

    def resolved_lama_dir(self) -> Path | None:
        candidate = self.lama_dir or (self.weights_dir / "big-lama")
        return candidate if candidate.exists() else None


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    """Cached so every module sees the same instance and the `.env` file
    is parsed once per process."""
    return Settings()
