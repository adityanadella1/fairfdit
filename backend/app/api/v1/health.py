"""Health and readiness.

Deliberately unauthenticated and deliberately cheap: this is what the
mobile client polls to decide whether to offer AI features at all, and
what an orchestrator polls to decide whether to route traffic. Neither
can afford it to load a model or take a GPU slot.
"""

from __future__ import annotations

from fastapi import APIRouter

from app.api.deps import get_segmentation_service
from app.config import get_settings
from app.engines.registry import engine_status
from app.schemas.common import EngineStatus, HealthResponse
from app.utils.device import describe_device
from app.workers.gpu_pool import get_pool

router = APIRouter(prefix="/v1", tags=["health"])


@router.get(
    "/health",
    response_model=HealthResponse,
    summary="Service and engine status",
)
async def health() -> HealthResponse:
    """Reports what this deployment can currently do.

    `status` is "ok" only when every engine is configured. A deployment
    missing, say, LaMa still answers 200 with "degraded" — it is serving
    traffic correctly, just not all of it, and returning an error status
    would take the whole service out of a load balancer over a partial
    capability gap.
    """
    settings = get_settings()
    service = get_segmentation_service()
    statuses = engine_status()

    return HealthResponse(
        status="ok" if all(s["configured"] for s in statuses.values()) else "degraded",
        version=settings.version,
        engines={
            name: EngineStatus(**status)  # type: ignore[arg-type]
            for name, status in statuses.items()
        },
        capabilities=(
            service.available_modes()
            + (["remove"] if service.remove_available() else [])
        ),
        device=describe_device(),
        queue_depth=get_pool().inflight,
    )


@router.get("/ready", summary="Liveness probe", include_in_schema=False)
async def ready() -> dict[str, bool]:
    """The narrowest possible check — the process is up and serving.

    Separate from /health because a container orchestrator restarting a
    pod over a missing optional checkpoint would be the wrong response to
    a degraded-but-working service.
    """
    return {"ready": True}
