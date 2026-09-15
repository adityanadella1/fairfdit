"""AI Remove: mask in, reconstructed image out."""

from __future__ import annotations

import logging
from dataclasses import dataclass

import numpy as np

from app.engines.mask_engine import Mask, MaskEngine
from app.engines.registry import lama_engine
from app.pipelines.base import NoSelectionFound

log = logging.getLogger(__name__)


@dataclass(slots=True)
class RemoveRequest:
    image: np.ndarray  # HWC uint8 RGB at full resolution
    mask: Mask
    #: Pixels of margin added around the mask before inpainting.
    dilate: int = 8


class AiRemovePipeline:
    """Removes the masked content and reconstructs what was behind it.

    Thin by design — LaMa does the work. What lives here is the input
    hygiene that decides whether the result looks like a removal or like
    a smudge.
    """

    name = "remove"

    def run(self, request: RemoveRequest) -> np.ndarray:
        engine = lama_engine()
        height, width = request.image.shape[:2]

        mask = MaskEngine.resize(request.mask, height, width)
        if mask.is_empty():
            raise NoSelectionFound("the mask is empty — nothing to remove")

        # A mask covering most of the frame is not a removal, it is an
        # image-generation request, and LaMa will return mush. Catching it
        # here gives the user a sentence instead of a ruined photo.
        if mask.coverage > 0.6:
            raise NoSelectionFound(
                "the area to remove covers most of the photo — "
                "select a smaller region"
            )

        # Close pinholes in the brushed region. A stroke with gaps leaves
        # islands of the original object behind, and LaMa treats those as
        # context and rebuilds the object around them.
        mask = MaskEngine.fill_holes(mask)

        log.info(
            "inpainting %dx%d, mask coverage %.2f%%",
            width,
            height,
            mask.coverage * 100,
        )
        return engine.inpaint(request.image, mask, dilate=request.dilate)
