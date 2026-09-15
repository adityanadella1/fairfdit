"""SAM 2, wrapped.

Reuses `sam2.build_sam`, `sam2.sam2_image_predictor` and
`sam2.automatic_mask_generator` exactly as upstream ships them — the
package is a dependency, not a copy. Nothing here reimplements
segmentation; this file exists to convert between the app's [Mask] type
and SAM's numpy conventions, and to own the predictor's image-embedding
lifecycle.
"""

from __future__ import annotations

import logging

import numpy as np

from app.config import get_settings
from app.engines.base import Engine, EngineUnavailable
from app.engines.mask_engine import Mask, MaskEngine
from app.utils.device import autocast_context, get_device

log = logging.getLogger(__name__)


class Sam2Engine(Engine):
    """Prompted segmentation: boxes and points in, masks out."""

    name = "sam2"

    def __init__(self) -> None:
        super().__init__()
        self._auto_generator = None

    def is_configured(self) -> bool:
        try:
            import sam2  # noqa: F401
        except ImportError:
            return False
        settings = get_settings()
        # Either a local checkpoint, or an HF id we are allowed to fetch.
        return bool(settings.resolved_sam2_checkpoint() or settings.sam2_hf_id)

    def _build(self):
        try:
            from sam2.build_sam import build_sam2
            from sam2.sam2_image_predictor import SAM2ImagePredictor
        except ImportError as exc:
            raise EngineUnavailable(
                "sam2 is not installed — run scripts/fetch_vendor.py or "
                "pip install the SAM 2 package"
            ) from exc

        settings = get_settings()
        device = get_device()
        checkpoint = settings.resolved_sam2_checkpoint()

        if checkpoint is not None:
            log.info("building SAM 2 from local checkpoint %s", checkpoint)
            # apply_postprocessing=False keeps SAM's own hole-filling out
            # of the way: MaskEngine does that step, so doing it twice
            # would round off small genuine gaps before we ever see them.
            model = build_sam2(
                settings.sam2_config,
                str(checkpoint),
                device=str(device),
                apply_postprocessing=False,
            )
            predictor = SAM2ImagePredictor(model)
        else:
            log.info("building SAM 2 from Hugging Face id %s", settings.sam2_hf_id)
            predictor = SAM2ImagePredictor.from_pretrained(
                settings.sam2_hf_id, device=str(device)
            )

        return predictor

    # --- Inference ---------------------------------------------------------

    @staticmethod
    def _torch():
        """Imported on use, not at module scope: /v1/health and the
        contract tests import this module to report capability, and
        neither should need a multi-gigabyte dependency to do it."""
        import torch

        return torch

    def segment_from_boxes(
        self,
        image: np.ndarray,
        boxes: list[tuple[float, float, float, float]],
        *,
        source: str = "sam2:box",
    ) -> list[Mask]:
        """One mask per box, prompted with normalised (l, t, r, b).

        Boxes are the strongest prompt SAM 2 takes and the reason the
        Grounding DINO handoff works so well: the detector says *where*,
        SAM says *exactly which pixels*.
        """
        if not boxes:
            return []

        predictor = self.model()
        height, width = image.shape[:2]
        pixel_boxes = np.array(
            [
                [
                    box[0] * width,
                    box[1] * height,
                    box[2] * width,
                    box[3] * height,
                ]
                for box in boxes
            ],
            dtype=np.float32,
        )

        torch = self._torch()
        with torch.inference_mode(), autocast_context():
            predictor.set_image(image)
            masks, scores, _ = predictor.predict(
                point_coords=None,
                point_labels=None,
                box=pixel_boxes,
                # One mask per box. Ambiguity resolution is what the box
                # prompt already provides, so asking for three and ranking
                # them buys nothing here.
                multimask_output=False,
            )

        return self._to_masks(masks, scores, boxes=boxes, source=source)

    def segment_from_points(
        self,
        image: np.ndarray,
        points: list[tuple[float, float]],
        labels: list[int] | None = None,
        *,
        source: str = "sam2:point",
    ) -> list[Mask]:
        """Point-prompted segmentation, for tap-to-select and for the
        user adding or removing regions from an existing selection.

        [labels] is 1 for "include this" and 0 for "exclude this",
        defaulting to all-include.
        """
        if not points:
            return []

        predictor = self.model()
        height, width = image.shape[:2]
        coords = np.array(
            [[x * width, y * height] for x, y in points], dtype=np.float32
        )
        point_labels = np.array(labels or [1] * len(points), dtype=np.int32)

        torch = self._torch()
        with torch.inference_mode(), autocast_context():
            predictor.set_image(image)
            masks, scores, _ = predictor.predict(
                point_coords=coords,
                point_labels=point_labels,
                # A single point is genuinely ambiguous (a shirt? a
                # person? a crowd?), so take all three candidates and let
                # the caller rank them.
                multimask_output=True,
            )

        return self._to_masks(masks, scores, source=source)

    def generate_automatic(
        self,
        image: np.ndarray,
        *,
        max_masks: int = 64,
        source: str = "sam2:auto",
    ) -> list[Mask]:
        """Unprompted segmentation of everything in the frame.

        This is what Select Subject ranks over when there is no detector
        hint to work from. Expensive — it runs the decoder over a point
        grid — so the grid is kept modest and the result count capped.
        """
        generator = self._automatic_mask_generator()
        torch = self._torch()
        with torch.inference_mode(), autocast_context():
            records = generator.generate(image)

        records.sort(
            key=lambda r: float(r.get("predicted_iou", 0.0)), reverse=True
        )
        return [
            MaskEngine.from_array(
                record["segmentation"],
                score=float(record.get("predicted_iou", 1.0)),
                source=source,
            )
            for record in records[:max_masks]
        ]

    def _automatic_mask_generator(self):
        if self._auto_generator is not None:
            return self._auto_generator

        try:
            from sam2.automatic_mask_generator import SAM2AutomaticMaskGenerator
        except ImportError as exc:
            raise EngineUnavailable("sam2 automatic mask generator unavailable") from exc

        predictor = self.model()
        self._auto_generator = SAM2AutomaticMaskGenerator(
            model=predictor.model,
            # 16x16 rather than the default 32x32: a quarter of the decoder
            # calls, and at the resolutions this service works at the extra
            # density mostly finds sub-object fragments we then discard.
            points_per_side=16,
            pred_iou_thresh=0.7,
            stability_score_thresh=0.88,
            # Drop specks below ~0.1% of a 1024px frame.
            min_mask_region_area=100,
        )
        return self._auto_generator

    @staticmethod
    def _to_masks(
        masks: np.ndarray,
        scores: np.ndarray,
        *,
        boxes: list[tuple[float, float, float, float]] | None = None,
        source: str,
    ) -> list[Mask]:
        """Normalises SAM's output, which is (N, H, W) for a batch of
        prompts but (H, W) when a single prompt was given."""
        array = np.asarray(masks)
        score_array = np.atleast_1d(np.asarray(scores)).astype(np.float32)
        if array.ndim == 2:
            array = array[None, ...]

        results: list[Mask] = []
        for index in range(array.shape[0]):
            score = float(score_array[index]) if index < score_array.size else 1.0
            results.append(
                MaskEngine.from_array(
                    array[index],
                    score=score,
                    source=source,
                    box=boxes[index] if boxes and index < len(boxes) else None,
                )
            )
        return results

    def unload(self) -> None:
        self._auto_generator = None
        super().unload()
