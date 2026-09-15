"""FastAPI dependencies: auth and service singletons."""

from __future__ import annotations

import secrets
from functools import lru_cache
from typing import Annotated

from fastapi import Depends, Header, HTTPException, status

from app.config import Settings, get_settings
from app.services.inpaint_service import InpaintService
from app.services.segmentation_service import SegmentationService


@lru_cache(maxsize=1)
def get_segmentation_service() -> SegmentationService:
    return SegmentationService()


@lru_cache(maxsize=1)
def get_inpaint_service() -> InpaintService:
    return InpaintService()


async def require_api_key(
    x_api_key: Annotated[str | None, Header(alias="X-API-Key")] = None,
    settings: Annotated[Settings, Depends(get_settings)] = None,  # type: ignore[assignment]
) -> None:
    """Shared-secret gate on the inference routes.

    No key configured means no gate — the right default for a service on a
    private network, and the reason the deployment docs are explicit about
    setting one before exposing it. Comparison is constant-time so a
    wrong key cannot be recovered a byte at a time from response latency.
    """
    expected = settings.api_key
    if not expected:
        return
    if not x_api_key or not secrets.compare_digest(x_api_key, expected):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or missing X-API-Key",
        )


SegmentationDep = Annotated[SegmentationService, Depends(get_segmentation_service)]
InpaintDep = Annotated[InpaintService, Depends(get_inpaint_service)]
