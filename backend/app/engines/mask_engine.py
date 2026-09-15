"""The one mask representation every feature speaks.

SAM 2, Grounding DINO, a future sky model and the client's brush tool all
produce something mask-shaped, in four different formats. [Mask] is what
they are all converted to on arrival, and [MaskEngine] is the only place
that manipulates one. The payoff is that "subtract the sky from the
subject selection" is the same code path whichever models produced those
two masks.

Invariant: a mask is always HW float32 in 0..1. Soft, not binary —
feathering and partial coverage are the whole point of a mask that drives
an exposure slider, and quantising to bool throws that away.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Iterable

import cv2
import numpy as np

from app.utils.image_io import encode_png

log = logging.getLogger(__name__)


@dataclass(slots=True)
class Mask:
    """One selection, plus where it came from.

    [score] and [source] travel with the mask so the API can report how
    confident a selection was without the pipeline having to thread that
    through separately.
    """

    data: np.ndarray  # HW float32, 0..1
    score: float = 1.0
    source: str = "unknown"
    #: Normalised (l, t, r, b) of whatever produced the mask, when a
    #: detector was involved.
    box: tuple[float, float, float, float] | None = None
    meta: dict[str, object] = field(default_factory=dict)

    def __post_init__(self) -> None:
        if self.data.ndim != 2:
            raise ValueError(f"mask must be 2-D, got shape {self.data.shape}")
        if self.data.dtype != np.float32:
            self.data = self.data.astype(np.float32)

    @property
    def shape(self) -> tuple[int, int]:
        return self.data.shape  # type: ignore[return-value]

    @property
    def height(self) -> int:
        return self.data.shape[0]

    @property
    def width(self) -> int:
        return self.data.shape[1]

    @property
    def coverage(self) -> float:
        """Fraction of the frame selected. Used to reject degenerate
        results — a mask covering 99.8% of the image is a failed
        selection, not a valid one."""
        return float(self.data.mean())

    def is_empty(self, threshold: float = 1e-4) -> bool:
        return self.coverage < threshold

    def to_uint8(self) -> np.ndarray:
        return np.clip(self.data * 255.0, 0, 255).astype(np.uint8)

    def to_png_base64(self) -> str:
        return encode_png(self.to_uint8())

    def copy(self) -> "Mask":
        return Mask(
            data=self.data.copy(),
            score=self.score,
            source=self.source,
            box=self.box,
            meta=dict(self.meta),
        )


class MaskEngine:
    """Stateless mask algebra and morphology.

    Every method is a classmethod returning a new [Mask]; nothing mutates
    its input. Masks flow through pipelines and get cached, and in-place
    edits to a shared array are exactly the kind of bug that shows up
    once in production and never in a test.
    """

    # --- Construction --------------------------------------------------

    @classmethod
    def create(
        cls,
        height: int,
        width: int,
        *,
        fill: float = 0.0,
        source: str = "created",
    ) -> Mask:
        """An empty (or uniformly filled) mask — the identity element for
        `add`, and the starting point for accumulating detections."""
        data = np.full((height, width), float(fill), dtype=np.float32)
        return Mask(data=data, source=source)

    @classmethod
    def from_array(
        cls,
        array: np.ndarray,
        *,
        score: float = 1.0,
        source: str = "array",
        box: tuple[float, float, float, float] | None = None,
    ) -> Mask:
        """Normalises anything mask-shaped into the canonical form.

        Handles the three things models actually hand back: a bool array,
        a uint8 image in 0..255, and a float array already in 0..1. A
        leading singleton batch/channel axis is squeezed, which is how
        SAM 2 and LaMa both return single masks.
        """
        data = np.asarray(array)
        while data.ndim > 2 and data.shape[0] == 1:
            data = data[0]
        if data.ndim == 3 and data.shape[-1] == 1:
            data = data[..., 0]
        if data.ndim != 2:
            raise ValueError(f"cannot interpret shape {array.shape} as a mask")

        if data.dtype == bool:
            data = data.astype(np.float32)
        elif np.issubdtype(data.dtype, np.integer):
            data = data.astype(np.float32) / 255.0
        else:
            data = data.astype(np.float32)

        return Mask(
            data=np.clip(data, 0.0, 1.0),
            score=float(score),
            source=source,
            box=box,
        )

    @classmethod
    def from_box(
        cls,
        height: int,
        width: int,
        box: tuple[float, float, float, float],
        *,
        source: str = "box",
    ) -> Mask:
        """A filled rectangle from a normalised (l, t, r, b).

        The fallback when a detector found something but segmentation
        failed: a box-shaped selection is crude, but it is a usable
        starting point the user can refine, which beats no mask at all.
        """
        left, top, right, bottom = box
        mask = cls.create(height, width, source=source)
        x0, x1 = sorted((int(left * width), int(right * width)))
        y0, y1 = sorted((int(top * height), int(bottom * height)))
        mask.data[
            max(0, y0) : min(height, y1),
            max(0, x0) : min(width, x1),
        ] = 1.0
        return mask

    # --- Boolean algebra -----------------------------------------------

    @classmethod
    def add(cls, a: Mask, b: Mask) -> Mask:
        """Union. Max rather than sum, so overlapping soft masks stay in
        0..1 instead of clipping to a hard edge where they meet."""
        cls._assert_same_shape(a, b)
        return Mask(
            data=np.maximum(a.data, b.data),
            score=max(a.score, b.score),
            source=f"{a.source}+{b.source}",
        )

    @classmethod
    def subtract(cls, a: Mask, b: Mask) -> Mask:
        """Everything in `a` that is not in `b`."""
        cls._assert_same_shape(a, b)
        return Mask(
            data=np.clip(a.data - b.data, 0.0, 1.0),
            score=a.score,
            source=f"{a.source}-{b.source}",
        )

    @classmethod
    def intersect(cls, a: Mask, b: Mask) -> Mask:
        """Overlap. Product rather than min, so two 50% soft regions
        intersect to 25% — the probabilistic reading, which is what
        feathered edges mean."""
        cls._assert_same_shape(a, b)
        return Mask(
            data=a.data * b.data,
            score=min(a.score, b.score),
            source=f"{a.source}&{b.source}",
        )

    @classmethod
    def invert(cls, mask: Mask) -> Mask:
        """The complement. This is the entire Select Background pipeline
        once a subject mask exists."""
        return Mask(
            data=1.0 - mask.data,
            score=mask.score,
            source=f"~{mask.source}",
            meta=dict(mask.meta),
        )

    @classmethod
    def union_all(cls, masks: Iterable[Mask]) -> Mask:
        """Folds a set of detections into one selection — how Select
        Person handles a photo with four people in it."""
        items = list(masks)
        if not items:
            raise ValueError("union_all needs at least one mask")
        result = items[0].copy()
        for other in items[1:]:
            result = cls.add(result, other)
        result.score = max(m.score for m in items)
        return result

    # --- Morphology ----------------------------------------------------

    @classmethod
    def expand(cls, mask: Mask, pixels: int) -> Mask:
        """Grows the selection (dilate). Negative values contract, so
        callers can expose a single signed "Refine" slider."""
        if pixels == 0:
            return mask.copy()
        if pixels < 0:
            return cls.contract(mask, -pixels)
        kernel = cls._kernel(pixels)
        return cls._respin(mask, cv2.dilate(mask.data, kernel), "expand")

    @classmethod
    def contract(cls, mask: Mask, pixels: int) -> Mask:
        """Shrinks the selection (erode).

        The usual fix for a mask that caught a halo of background along a
        subject's edge — pulling in a pixel or two removes it without
        touching the interior.
        """
        if pixels <= 0:
            return mask.copy()
        kernel = cls._kernel(pixels)
        return cls._respin(mask, cv2.erode(mask.data, kernel), "contract")

    @classmethod
    def feather(cls, mask: Mask, radius: float) -> Mask:
        """Softens the edge with a Gaussian blur.

        Applied to the whole mask rather than just the boundary because a
        blur of a binary mask *is* an edge-only operation — the interior
        is already saturated and the blur leaves it unchanged.
        """
        if radius <= 0:
            return mask.copy()
        # OpenCV needs an odd kernel; sigma is derived from the radius so
        # the visible falloff matches what the caller asked for.
        ksize = int(radius) * 2 + 1
        blurred = cv2.GaussianBlur(mask.data, (ksize, ksize), radius / 2.0)
        return cls._respin(mask, blurred, "feather")

    @classmethod
    def smooth(cls, mask: Mask, radius: int = 3) -> Mask:
        """Removes staircase and speckle along the boundary without
        moving it, by opening then closing at the same radius."""
        if radius <= 0:
            return mask.copy()
        kernel = cls._kernel(radius)
        opened = cv2.morphologyEx(mask.data, cv2.MORPH_OPEN, kernel)
        closed = cv2.morphologyEx(opened, cv2.MORPH_CLOSE, kernel)
        return cls._respin(mask, closed, "smooth")

    @classmethod
    def fill_holes(cls, mask: Mask) -> Mask:
        """Closes interior gaps — the sky seen through a window in a
        building the user asked to select, or the gap between an arm and
        a torso that segmentation missed."""
        binary = (mask.data > 0.5).astype(np.uint8)
        # Flood from the border: whatever the fill cannot reach is an
        # enclosed hole, by definition.
        h, w = binary.shape
        flood = binary.copy()
        scratch = np.zeros((h + 2, w + 2), np.uint8)
        cv2.floodFill(flood, scratch, (0, 0), 1)
        holes = (flood == 0).astype(np.float32)
        return cls._respin(mask, np.maximum(mask.data, holes), "fill_holes")

    @classmethod
    def remove_holes(cls, mask: Mask, min_area: int = 64) -> Mask:
        """Drops disconnected specks smaller than [min_area].

        Detectors routinely emit a handful of stray pixels alongside the
        real selection; left in, they show up as confetti once the mask
        drives an adjustment.
        """
        binary = (mask.data > 0.5).astype(np.uint8)
        count, labels, stats, _ = cv2.connectedComponentsWithStats(binary, 8)
        if count <= 1:
            return mask.copy()

        keep = np.zeros_like(binary, dtype=bool)
        for index in range(1, count):  # 0 is the background component
            if stats[index, cv2.CC_STAT_AREA] >= min_area:
                keep |= labels == index
        return cls._respin(mask, mask.data * keep, "remove_holes")

    @classmethod
    def keep_largest_component(cls, mask: Mask) -> Mask:
        """Reduces to the single biggest blob. Used where the target is
        known to be one object, so a second detection is noise."""
        binary = (mask.data > 0.5).astype(np.uint8)
        count, labels, stats, _ = cv2.connectedComponentsWithStats(binary, 8)
        if count <= 2:  # background plus at most one component
            return mask.copy()
        largest = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
        return cls._respin(mask, mask.data * (labels == largest), "largest")

    # --- Edge refinement -------------------------------------------------

    @classmethod
    def refine_edges(
        cls,
        mask: Mask,
        image: np.ndarray | None = None,
        *,
        radius: int = 6,
    ) -> Mask:
        """Snaps the mask boundary onto the image's own edges.

        SAM 2's masks are excellent but decoded at 256x256 and upsampled,
        so the boundary sits a pixel or two off the real one on hair,
        fur and foliage. A guided filter re-derives the edge from the
        image's own gradients, which is far cheaper than a matting
        network and fixes most of the visible gap.

        Falls back to feather+smooth when no image is available or when
        OpenCV was built without ximgproc.
        """
        if image is None:
            return cls.smooth(cls.feather(mask, 1.5), 2)

        try:
            from cv2 import ximgproc  # type: ignore[attr-defined]
        except (ImportError, AttributeError):
            log.debug("cv2.ximgproc unavailable; falling back to feather+smooth")
            return cls.smooth(cls.feather(mask, 1.5), 2)

        guide = image
        if guide.shape[:2] != mask.shape:
            guide = cv2.resize(
                guide, (mask.width, mask.height), interpolation=cv2.INTER_AREA
            )

        refined = ximgproc.guidedFilter(
            guide=cv2.cvtColor(guide, cv2.COLOR_RGB2BGR),
            src=mask.data,
            radius=radius,
            eps=1e-4,
        )
        return cls._respin(mask, refined, "refine_edges")

    # --- Geometry ---------------------------------------------------------

    @classmethod
    def resize(cls, mask: Mask, height: int, width: int) -> Mask:
        """Resamples to an exact size, bilinearly so soft edges survive."""
        if mask.shape == (height, width):
            return mask.copy()
        resized = cv2.resize(
            mask.data, (width, height), interpolation=cv2.INTER_LINEAR
        )
        return cls._respin(mask, resized, "resize")

    @classmethod
    def bounding_box(cls, mask: Mask) -> tuple[float, float, float, float] | None:
        """Normalised (l, t, r, b) of the selected region, or None if
        nothing is selected."""
        ys, xs = np.nonzero(mask.data > 0.5)
        if ys.size == 0:
            return None
        return (
            float(xs.min() / mask.width),
            float(ys.min() / mask.height),
            float((xs.max() + 1) / mask.width),
            float((ys.max() + 1) / mask.height),
        )

    # --- Serialisation -----------------------------------------------------

    @classmethod
    def serialize(cls, mask: Mask) -> dict[str, object]:
        """The wire form. PNG rather than raw bytes: a mask is mostly flat
        regions, which PNG compresses by an order of magnitude, and the
        client can decode it with the image codec it already has."""
        return {
            "mask": mask.to_png_base64(),
            "width": mask.width,
            "height": mask.height,
            "score": round(mask.score, 4),
            "coverage": round(mask.coverage, 4),
            "box": list(mask.box) if mask.box else None,
            "source": mask.source,
        }

    # --- Internals ----------------------------------------------------------

    @staticmethod
    def _kernel(radius: int) -> np.ndarray:
        size = max(1, int(radius)) * 2 + 1
        return cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (size, size))

    @staticmethod
    def _respin(original: Mask, data: np.ndarray, op: str) -> Mask:
        """Rebuilds a mask around new pixel data, carrying the provenance
        fields forward so a mask never loses its score after morphology."""
        return Mask(
            data=np.clip(data.astype(np.float32), 0.0, 1.0),
            score=original.score,
            source=f"{original.source}|{op}",
            box=original.box,
            meta=dict(original.meta),
        )

    @staticmethod
    def _assert_same_shape(a: Mask, b: Mask) -> None:
        if a.shape != b.shape:
            raise ValueError(
                f"mask shapes differ: {a.shape} vs {b.shape}; "
                "resize one before combining"
            )
