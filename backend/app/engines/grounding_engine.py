"""Grounding DINO, wrapped.

Reuses `groundingdino.util.inference.load_model` / `predict` and the
repository's own `datasets/transforms.py` — the two pieces the upstream
README points at for inference. Everything else in that repository
(training, COCO evaluation, the demo app) is deliberately not vendored.

The engine's job in this service is narrow: turn a noun into boxes, which
then become SAM 2 prompts.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass

import numpy as np

from app.config import get_settings
from app.engines.base import Engine, EngineUnavailable
from app.utils.device import get_device

log = logging.getLogger(__name__)


@dataclass(slots=True)
class Detection:
    """One detected object.

    [box] is normalised (l, t, r, b) — converted here from the model's
    native centre-width-height form so nothing downstream has to remember
    which convention it is holding.
    """

    box: tuple[float, float, float, float]
    score: float
    label: str


class GroundingEngine(Engine):
    """Open-vocabulary detection: a text prompt in, boxes out."""

    name = "grounding_dino"

    def __init__(self) -> None:
        super().__init__()
        self._transform = None

    def is_configured(self) -> bool:
        try:
            import groundingdino  # noqa: F401
        except ImportError:
            return False
        config, weights = get_settings().resolved_grounding_paths()
        return config is not None and weights is not None

    def _build(self):
        try:
            from groundingdino.util.inference import load_model
        except ImportError as exc:
            raise EngineUnavailable(
                "groundingdino is not installed — run scripts/fetch_vendor.py"
            ) from exc

        config, weights = get_settings().resolved_grounding_paths()
        if config is None or weights is None:
            raise EngineUnavailable(
                "Grounding DINO config or checkpoint is missing — run "
                "scripts/download_weights.py"
            )

        device = get_device()
        log.info("building Grounding DINO from %s", weights)
        model = load_model(str(config), str(weights), device=str(device))
        return model.to(device).eval()

    def _image_transform(self):
        """The exact preprocessing the released weights were trained with.

        Taken from the repository's own `datasets/transforms.py` rather
        than reimplemented: resize-shortest-side-to-800 with a 1333 cap,
        then ImageNet normalisation. Getting either detail wrong silently
        degrades detection rather than erroring, which is the worst kind
        of bug to chase.
        """
        if self._transform is not None:
            return self._transform

        try:
            import groundingdino.datasets.transforms as T
        except ImportError as exc:
            raise EngineUnavailable("groundingdino transforms unavailable") from exc

        self._transform = T.Compose(
            [
                T.RandomResize([800], max_size=1333),
                T.ToTensor(),
                T.Normalize([0.485, 0.456, 0.406], [0.229, 0.224, 0.225]),
            ]
        )
        return self._transform

    # --- Inference ---------------------------------------------------------

    def detect(
        self,
        image: np.ndarray,
        prompt: str,
        *,
        box_threshold: float | None = None,
        text_threshold: float | None = None,
        max_detections: int = 10,
    ) -> list[Detection]:
        """Detects every instance matching [prompt].

        The caption is normalised to the form the model expects: lower
        case, period-terminated. Upstream is explicit that phrases are
        separated by periods, and a caption without one detects
        noticeably worse.
        """
        import torch
        from groundingdino.util.inference import predict
        from PIL import Image

        settings = get_settings()
        model = self.model()
        caption = self._normalise_caption(prompt)

        transform = self._image_transform()
        # The transform's signature is (PIL image, target) and it returns
        # the pair; only the tensor is needed at inference time.
        tensor, _ = transform(Image.fromarray(image), None)

        with torch.inference_mode():
            boxes, logits, phrases = predict(
                model=model,
                image=tensor,
                caption=caption,
                box_threshold=(
                    settings.grounding_box_threshold
                    if box_threshold is None
                    else box_threshold
                ),
                text_threshold=(
                    settings.grounding_text_threshold
                    if text_threshold is None
                    else text_threshold
                ),
                device=str(get_device()),
            )

        detections = [
            Detection(
                box=self._cxcywh_to_ltrb(box),
                score=float(score),
                label=phrase,
            )
            for box, score, phrase in zip(
                boxes.cpu().numpy(), logits.cpu().numpy(), phrases, strict=False
            )
        ]
        detections.sort(key=lambda d: d.score, reverse=True)

        log.debug(
            "grounding '%s' -> %d detections (top score %.2f)",
            caption,
            len(detections),
            detections[0].score if detections else 0.0,
        )
        return detections[:max_detections]

    def detect_best(self, image: np.ndarray, prompt: str) -> Detection | None:
        """The single highest-scoring detection, or None."""
        detections = self.detect(image, prompt, max_detections=1)
        return detections[0] if detections else None

    # --- Helpers -----------------------------------------------------------

    @staticmethod
    def _normalise_caption(prompt: str) -> str:
        caption = prompt.strip().lower()
        if not caption:
            raise ValueError("prompt must not be empty")
        if not caption.endswith("."):
            caption += "."
        return caption

    @staticmethod
    def _cxcywh_to_ltrb(box: np.ndarray) -> tuple[float, float, float, float]:
        """Converts a normalised centre/size box to normalised corners,
        clamped to the frame so a detection that runs off the edge cannot
        produce an out-of-range SAM prompt."""
        cx, cy, w, h = (float(v) for v in box)
        return (
            max(0.0, cx - w / 2),
            max(0.0, cy - h / 2),
            min(1.0, cx + w / 2),
            min(1.0, cy + h / 2),
        )
