"""Pipeline contract and shared post-processing.

A pipeline composes engines into one user-facing capability ("select the
subject"). It never touches HTTP and never touches a repository's code
directly — it calls engines, and the engines own the upstream libraries.
"""

from __future__ import annotations

import logging
from abc import ABC, abstractmethod
from dataclasses import dataclass

import numpy as np

from app.engines.mask_engine import Mask, MaskEngine

log = logging.getLogger(__name__)


class NoSelectionFound(RuntimeError):
    """The pipeline ran correctly and found nothing to select.

    A normal outcome ("there is no dog in this photo"), not a failure —
    the API answers 404 so the client can say so plainly rather than
    showing an error.
    """


@dataclass(slots=True)
class SelectionRequest:
    """Everything a pipeline needs, already decoded and validated."""

    image: np.ndarray  # HWC uint8 RGB, already downscaled for inference
    prompt: str | None = None
    refine_edges: bool = True
    #: Signed pixels applied to the final mask: positive grows the
    #: selection, negative pulls it in.
    grow: int = 0
    feather: float = 0.0


class Pipeline(ABC):
    """One selection capability."""

    name: str = "pipeline"

    @abstractmethod
    def run(self, request: SelectionRequest) -> Mask:
        """Produces the selection, or raises [NoSelectionFound]."""

    # --- Shared post-processing ------------------------------------------

    def postprocess(self, mask: Mask, request: SelectionRequest) -> Mask:
        """The cleanup every selection gets, in a fixed order.

        The order matters and is the same one a retoucher would use:
        remove specks, close interior gaps, snap the edge to the image,
        then apply the user's own grow/feather last so their adjustment
        is not undone by a later morphological step.
        """
        # 0.05% of the frame — below this a component is detector noise,
        # not something anyone meant to select.
        min_area = max(16, int(mask.height * mask.width * 0.0005))
        result = MaskEngine.remove_holes(mask, min_area=min_area)
        result = MaskEngine.fill_holes(result)

        if request.refine_edges:
            result = MaskEngine.refine_edges(result, request.image)

        if request.grow:
            result = MaskEngine.expand(result, request.grow)
        if request.feather > 0:
            result = MaskEngine.feather(result, request.feather)

        if result.is_empty():
            raise NoSelectionFound(
                "the selection was empty after cleanup — try a different prompt"
            )
        return result

    @staticmethod
    def reject_degenerate(mask: Mask, *, max_coverage: float = 0.995) -> Mask:
        """Guards against a "selection" that is the entire frame.

        A near-total mask usually means the detector latched onto the
        background; passing it through would give the user an adjustment
        that looks global and a masking UI that looks broken.
        """
        if mask.coverage > max_coverage:
            raise NoSelectionFound(
                "the selection covered the whole image — try a narrower prompt"
            )
        return mask
