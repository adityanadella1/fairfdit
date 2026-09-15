"""POST /v1/segment"""

from __future__ import annotations

from fastapi import APIRouter, Depends, status

from app.api.deps import SegmentationDep, require_api_key
from app.schemas.common import ErrorResponse
from app.schemas.segment import SegmentRequest, SegmentResponse

router = APIRouter(
    prefix="/v1",
    tags=["segmentation"],
    dependencies=[Depends(require_api_key)],
)


@router.post(
    "/segment",
    response_model=SegmentResponse,
    summary="Produce a selection mask",
    responses={
        400: {"model": ErrorResponse, "description": "Malformed image or prompt"},
        404: {"model": ErrorResponse, "description": "Nothing matched"},
        503: {"model": ErrorResponse, "description": "Engine unavailable or busy"},
        504: {"model": ErrorResponse, "description": "Inference timed out"},
    },
)
async def segment(
    request: SegmentRequest,
    service: SegmentationDep,
) -> SegmentResponse:
    """Runs the pipeline for `mode` and returns one mask.

    The mask comes back at the dimensions of the image that was sent,
    whatever resolution inference actually ran at, so the client can
    composite it directly.

    Every failure mode is an explicit status: 404 means the pipeline ran
    and found nothing (a real answer, not a bug), 503 means this
    deployment cannot serve that mode or is saturated.
    """
    return await service.segment(request)


@router.get(
    "/segment/modes",
    summary="Selection modes this deployment can serve",
    status_code=status.HTTP_200_OK,
)
async def modes(service: SegmentationDep) -> dict[str, list[str]]:
    """Lets a client discover capability instead of probing for it."""
    return {"modes": service.available_modes()}
