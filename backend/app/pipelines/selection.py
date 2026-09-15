"""The five selection pipelines.

They share one module because they are variations on a single flow —
locate, segment, clean up — and keeping them adjacent makes the
differences between them legible instead of scattered across five files.

    Select Subject     SAM 2 automatic  -> rank -> best mask
    Select Person      DINO "person"    -> boxes -> SAM 2 -> union
    Select Object      DINO <prompt>    -> boxes -> SAM 2 -> union
    Select Sky         DINO "sky"       -> boxes -> SAM 2 -> union
    Select Background  Select Subject   -> invert
"""

from __future__ import annotations

import logging

import numpy as np

from app.engines.mask_engine import Mask, MaskEngine
from app.engines.registry import grounding_engine, sam2_engine
from app.pipelines.base import NoSelectionFound, Pipeline, SelectionRequest

log = logging.getLogger(__name__)


class SelectSubjectPipeline(Pipeline):
    """The main subject of the photo, with no prompt from the user.

    Tries the detector first: "the main subject" is almost always a
    person or an animal, and a detected box gives SAM a far stronger
    prompt than a point grid does. Only when nothing is detected does it
    fall back to automatic mask generation and ranking, which is slower
    and less reliable but works on anything.
    """

    name = "subject"

    #: Nouns tried in order. First hit wins, so a photo containing both a
    #: person and a dog selects the person — which is what "the subject"
    #: means in a portrait.
    SUBJECT_PROMPTS = ("person", "animal", "car", "product")

    def run(self, request: SelectionRequest) -> Mask:
        detector = grounding_engine()

        if detector.is_configured():
            for prompt in self.SUBJECT_PROMPTS:
                try:
                    detections = detector.detect(
                        request.image, prompt, max_detections=5
                    )
                except Exception:  # noqa: BLE001 - detector is best-effort here
                    log.warning("detector failed on '%s'; continuing", prompt)
                    break
                if detections:
                    log.debug("subject matched '%s'", prompt)
                    masks = sam2_engine().segment_from_boxes(
                        request.image,
                        [d.box for d in detections],
                        source=f"subject:{prompt}",
                    )
                    if masks:
                        return self.postprocess(
                            self.reject_degenerate(MaskEngine.union_all(masks)),
                            request,
                        )

        log.debug("no detector hit; falling back to automatic segmentation")
        return self.postprocess(self._from_automatic(request.image), request)

    def _from_automatic(self, image: np.ndarray) -> Mask:
        """Ranks unprompted masks and takes the best one."""
        candidates = sam2_engine().generate_automatic(image, max_masks=32)
        if not candidates:
            raise NoSelectionFound("nothing could be segmented in this image")

        height, width = image.shape[:2]
        best = max(candidates, key=lambda m: self._rank(m, height, width))
        return self.reject_degenerate(best)

    @staticmethod
    def _rank(mask: Mask, height: int, width: int) -> float:
        """Scores a candidate on how subject-like it is.

        Three signals, because no single one is sufficient: the model's
        own confidence, a size preference that penalises both specks and
        whole-frame regions, and centrality — photographers put the
        subject near the middle far more often than not.
        """
        coverage = mask.coverage
        if coverage < 0.01 or coverage > 0.9:
            return 0.0

        # Peaks around 25% of the frame and falls off either side.
        size_score = 1.0 - abs(coverage - 0.25) / 0.65

        ys, xs = np.nonzero(mask.data > 0.5)
        if ys.size == 0:
            return 0.0
        cy = ys.mean() / height
        cx = xs.mean() / width
        distance = float(np.hypot(cx - 0.5, cy - 0.5))
        centre_score = 1.0 - min(distance / 0.7071, 1.0)

        return 0.4 * mask.score + 0.35 * size_score + 0.25 * centre_score


class GroundedSelectionPipeline(Pipeline):
    """Shared body of every "find this noun, then segment it" pipeline.

    Select Person, Select Object and Select Sky differ only in where the
    noun comes from, so they are three thin subclasses over one
    implementation rather than three copies of it.
    """

    #: Fixed noun, or None to use the caller's prompt.
    fixed_prompt: str | None = None

    #: Collapse every detection into one mask. True for "select all the
    #: people"; False where the single best match is wanted.
    union_detections: bool = True

    def resolve_prompt(self, request: SelectionRequest) -> str:
        if self.fixed_prompt:
            return self.fixed_prompt
        prompt = (request.prompt or "").strip()
        if not prompt:
            raise NoSelectionFound("no prompt was given for this selection")
        return prompt

    def run(self, request: SelectionRequest) -> Mask:
        detector = grounding_engine()
        if not detector.is_configured():
            raise NoSelectionFound(
                "text-prompted selection needs Grounding DINO, which is not "
                "installed on this server"
            )

        prompt = self.resolve_prompt(request)
        detections = detector.detect(request.image, prompt, max_detections=10)
        if not detections:
            raise NoSelectionFound(f"no '{prompt}' was found in this image")

        if not self.union_detections:
            detections = detections[:1]

        masks = sam2_engine().segment_from_boxes(
            request.image,
            [d.box for d in detections],
            source=f"{self.name}:{prompt}",
        )
        if not masks:
            # The detector was confident but SAM produced nothing. A
            # box-shaped mask is a poor selection, but it is a real one
            # the user can refine by hand — better than an error.
            log.warning("segmentation returned nothing; falling back to boxes")
            height, width = request.image.shape[:2]
            masks = [
                MaskEngine.from_box(height, width, d.box, source=f"{self.name}:box")
                for d in detections
            ]

        combined = MaskEngine.union_all(masks)
        combined.box = detections[0].box
        combined.score = detections[0].score
        return self.postprocess(self.reject_degenerate(combined), request)


class SelectPersonPipeline(GroundedSelectionPipeline):
    """Every person in the frame."""

    name = "person"
    fixed_prompt = "person"


class SelectObjectPipeline(GroundedSelectionPipeline):
    """Whatever the user typed."""

    name = "object"
    fixed_prompt = None


class SelectSkyPipeline(GroundedSelectionPipeline):
    """The sky.

    Routed through the detector today, which handles ordinary skylines
    well. A dedicated sky-segmentation model would do better on the hard
    cases — branches, reflections, thin gaps between buildings — and can
    replace the body of this class without touching anything else,
    because the pipeline boundary is the mask, not the method.
    """

    name = "sky"
    fixed_prompt = "sky"

    def run(self, request: SelectionRequest) -> Mask:
        mask = super().run(request)
        # Sky masks are one connected region far more often than not, and
        # detector noise on a bright building reads as a second "sky".
        return MaskEngine.keep_largest_component(mask)


class SelectBackgroundPipeline(Pipeline):
    """Everything the subject is not.

    Deliberately defined as the inverse of Select Subject rather than as
    its own model: any improvement to subject detection is automatically
    an improvement here, and the two can never disagree about where the
    boundary is.
    """

    name = "background"

    def __init__(self) -> None:
        self._subject = SelectSubjectPipeline()

    def run(self, request: SelectionRequest) -> Mask:
        # Edge refinement and grow/feather are applied to the *subject*
        # before inverting, so a grow of +4 grows the subject and the
        # background shrinks to match — inverting afterwards would grow
        # the background into the subject instead.
        subject = self._subject.run(request)
        background = MaskEngine.invert(subject)
        background.source = "background"
        background.score = subject.score
        return background
