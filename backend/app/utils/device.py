"""Device and dtype selection.

Isolated so that every engine picks the same device by the same rules.

torch is imported inside the functions rather than at module scope. That
is not a style choice: `/v1/health` and the contract tests reach this
module to *report* what the machine can do, and neither should need a
multi-gigabyte dependency installed to answer. On a box without torch the
service still boots, still serves health, and reports every engine as
unconfigured — which is exactly what is true.
"""

from __future__ import annotations

import logging
from functools import lru_cache
from typing import TYPE_CHECKING, Any

from app.config import get_settings

if TYPE_CHECKING:  # pragma: no cover - typing only
    import torch

log = logging.getLogger(__name__)


def torch_available() -> bool:
    try:
        import torch  # noqa: F401
    except ImportError:
        return False
    return True


@lru_cache(maxsize=1)
def get_device() -> "torch.device":
    """Resolves the configured device, falling back rather than crashing.

    `auto` prefers CUDA, then Apple's MPS, then CPU. An explicit setting
    that is not actually available is downgraded with a warning: a service
    that boots degraded and says so is more useful than one that refuses
    to start on a machine without the GPU it expected.
    """
    import torch

    configured = get_settings().device

    if configured in {"cuda", "auto"} and torch.cuda.is_available():
        return torch.device("cuda")
    if configured == "cuda":
        log.warning("device=cuda requested but CUDA is unavailable; using CPU")
        return torch.device("cpu")

    mps_ok = torch.backends.mps.is_available() and torch.backends.mps.is_built()
    if configured in {"mps", "auto"} and mps_ok:
        return torch.device("mps")
    if configured == "mps":
        log.warning("device=mps requested but MPS is unavailable; using CPU")

    return torch.device("cpu")


@lru_cache(maxsize=1)
def get_dtype() -> "torch.dtype":
    """Half precision only where it is actually a win.

    On CUDA: bfloat16 on Ampere and newer (wider exponent range, so no
    loss scaling needed) and float16 below it. Everywhere else float32 —
    CPU float16 is emulated and slower, and MPS half support is uneven.
    """
    import torch

    if not get_settings().use_fp16 or get_device().type != "cuda":
        return torch.float32
    if torch.cuda.get_device_capability()[0] >= 8:
        return torch.bfloat16
    return torch.float16


def autocast_context() -> Any:
    """Autocast for the active device, or a no-op elsewhere."""
    import torch

    device = get_device()
    dtype = get_dtype()
    if device.type == "cuda" and dtype != torch.float32:
        return torch.autocast(device_type="cuda", dtype=dtype)
    return torch.autocast(device_type="cpu", enabled=False)


def describe_device() -> dict[str, object]:
    """Device facts for the health endpoint.

    Everything here is diagnostics an operator needs when a deployment is
    unexpectedly slow — most often "it is silently on CPU".
    """
    if not torch_available():
        return {"device": "unavailable", "detail": "torch is not installed"}

    device = get_device()
    info: dict[str, object] = {"device": device.type, "dtype": str(get_dtype())}
    if device.type == "cuda":
        import torch

        free, total = torch.cuda.mem_get_info()
        info |= {
            "gpu_name": torch.cuda.get_device_name(0),
            "vram_free_mb": round(free / 1024**2),
            "vram_total_mb": round(total / 1024**2),
        }
    return info


def empty_cache() -> None:
    """Returns cached blocks to the driver. Worth calling after a large
    inpaint, whose activations can hold hundreds of MB the next (smaller)
    request has no use for."""
    if not torch_available():
        return
    if get_device().type == "cuda":
        import torch

        torch.cuda.empty_cache()
