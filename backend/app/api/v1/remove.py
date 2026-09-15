"""POST /v1/remove"""

from __future__ import annotations

from fastapi import APIRouter, Depends

from app.api.deps import InpaintDep, require_api_key
from app.schemas.common import ErrorResponse
from app.schemas.remove import RemoveRequest, RemoveResponse

router = APIRouter(
    prefix="/v1",
    tags=["inpainting"],
    dependencies=[Depends(require_api_key)],
)


@router.post(
    "/remove",
    response_model=RemoveResponse,
    summary="Remove the masked region and reconstruct behind it",
    responses={
        400: {"model": ErrorResponse, "description": "Malformed image or mask"},
        404: {"model": ErrorResponse, "description": "Empty or oversized mask"},
        503: {"model": ErrorResponse, "description": "Engine unavailable or busy"},
        504: {"model": ErrorResponse, "description": "Inference timed out"},
    },
)
async def remove(
    request: RemoveRequest,
    service: InpaintDep,
) -> RemoveResponse:
    """Inpaints `mask` out of `image`.

    The mask may be at any resolution; it is matched to the image. A mask
    covering more than 60% of the frame is refused rather than attempted
    — past that point the model is generating an image rather than
    reconstructing a background, and the result is not usable.
    """
    return await service.remove(request)
