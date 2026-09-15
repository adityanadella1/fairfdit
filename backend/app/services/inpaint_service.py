"""Inpainting service — the layer behind POST /v1/remove."""

from __future__ import annotations

import logging
import time

from app.engines.mask_engine import MaskEngine
from app.pipelines.ai_remove import AiRemovePipeline, RemoveRequest as PipelineRequest
from app.schemas.remove import RemoveRequest, RemoveResponse
from app.utils.image_io import decode_base64_image, decode_base64_mask, encode_png
from app.workers.gpu_pool import get_pool

log = logging.getLogger(__name__)


class InpaintService:
    def __init__(self) -> None:
        self._pipeline = AiRemovePipeline()

    async def remove(self, request: RemoveRequest) -> RemoveResponse:
        started = time.perf_counter()

        image = decode_base64_image(request.image)
        mask_array = decode_base64_mask(request.mask)
        mask = MaskEngine.from_array(mask_array, source="client")

        # The client is free to send a mask at its own working resolution
        # — it often has one lying around at half size — so it is matched
        # to the image here rather than being rejected.
        height, width = image.shape[:2]
        if mask.shape != (height, width):
            log.debug(
                "resizing client mask %s -> %s", mask.shape, (height, width)
            )
            mask = MaskEngine.resize(mask, height, width)

        result = await get_pool().run(
            self._pipeline.run,
            PipelineRequest(image=image, mask=mask, dilate=request.dilate),
            label="remove",
        )

        elapsed_ms = int((time.perf_counter() - started) * 1000)
        log.info("remove %dx%d in %dms", width, height, elapsed_ms)

        return RemoveResponse(
            image=encode_png(result),
            width=result.shape[1],
            height=result.shape[0],
            elapsed_ms=elapsed_ms,
        )
