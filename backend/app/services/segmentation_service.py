"""Segmentation service.

The layer the API talks to. It owns request-shaped concerns — decoding,
resolution management, pipeline routing, scaling results back to the
caller's geometry — so routes stay declarative and pipelines stay free of
transport details.
"""

from __future__ import annotations

import logging
import time

from app.config import get_settings
from app.engines.mask_engine import Mask, MaskEngine
from app.engines.registry import grounding_engine, lama_engine, sam2_engine
from app.pipelines.base import Pipeline, SelectionRequest
from app.pipelines.selection import (
    SelectBackgroundPipeline,
    SelectObjectPipeline,
    SelectPersonPipeline,
    SelectSkyPipeline,
    SelectSubjectPipeline,
)
from app.schemas.segment import SegmentMode, SegmentRequest, SegmentResponse
from app.utils.image_io import decode_base64_image, fit_within
from app.workers.gpu_pool import get_pool

log = logging.getLogger(__name__)


class SegmentationService:
    """Routes a [SegmentRequest] to the right pipeline and returns the
    mask at the caller's original resolution."""

    def __init__(self) -> None:
        # Pipelines are stateless and cheap; building them once keeps the
        # per-request path allocation-free.
        self._pipelines: dict[SegmentMode, Pipeline] = {
            SegmentMode.SUBJECT: SelectSubjectPipeline(),
            SegmentMode.PERSON: SelectPersonPipeline(),
            SegmentMode.OBJECT: SelectObjectPipeline(),
            SegmentMode.SKY: SelectSkyPipeline(),
            SegmentMode.BACKGROUND: SelectBackgroundPipeline(),
        }

    # --- Capability reporting ------------------------------------------

    def available_modes(self) -> list[str]:
        """Modes this deployment can actually serve right now.

        Reported through /v1/health so the client greys out what it cannot
        use rather than offering a button that returns 503.
        """
        modes: list[str] = []
        if sam2_engine().is_configured():
            # Subject falls back to SAM's automatic generator when no
            # detector is present, so these three need SAM alone.
            modes += [
                SegmentMode.SUBJECT.value,
                SegmentMode.BACKGROUND.value,
            ]
            if grounding_engine().is_configured():
                modes += [
                    SegmentMode.PERSON.value,
                    SegmentMode.OBJECT.value,
                    SegmentMode.SKY.value,
                ]
        return modes

    @staticmethod
    def remove_available() -> bool:
        return lama_engine().is_configured()

    # --- Inference ------------------------------------------------------

    async def segment(self, request: SegmentRequest) -> SegmentResponse:
        started = time.perf_counter()
        settings = get_settings()

        image = decode_base64_image(request.image)
        original_h, original_w = image.shape[:2]

        # Inference runs at a bounded resolution and the mask is scaled
        # back up. Segmentation quality saturates well below 4K, and the
        # attention cost does not.
        working, _ = fit_within(image, settings.max_inference_dimension)

        pipeline = self._pipelines[request.mode]
        selection = SelectionRequest(
            image=working,
            prompt=request.prompt,
            refine_edges=request.refine_edges,
            grow=request.grow,
            feather=request.feather,
        )

        mask: Mask = await get_pool().run(
            pipeline.run,
            selection,
            label=f"segment:{request.mode.value}",
        )

        # Back to the caller's geometry, so the client can composite the
        # mask against the image it sent without any scaling of its own.
        mask = MaskEngine.resize(mask, original_h, original_w)

        elapsed_ms = int((time.perf_counter() - started) * 1000)
        log.info(
            "segment mode=%s prompt=%r coverage=%.3f in %dms",
            request.mode.value,
            request.prompt,
            mask.coverage,
            elapsed_ms,
        )

        return SegmentResponse(
            mask=mask.to_png_base64(),
            width=mask.width,
            height=mask.height,
            score=min(max(mask.score, 0.0), 1.0),
            coverage=mask.coverage,
            box=list(mask.box) if mask.box else MaskEngine.bounding_box(mask),
            mode=request.mode,
            prompt=request.prompt,
            source=mask.source,
            elapsed_ms=elapsed_ms,
        )
