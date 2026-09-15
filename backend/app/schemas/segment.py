"""Request and response contracts for POST /v1/segment."""

from __future__ import annotations

from enum import StrEnum

from pydantic import BaseModel, Field, field_validator, model_validator


class SegmentMode(StrEnum):
    """Must stay in step with `AiMaskMode` in the Flutter client — these
    strings are the wire contract between them."""

    SUBJECT = "subject"
    PERSON = "person"
    OBJECT = "object"
    BACKGROUND = "background"
    SKY = "sky"

    @property
    def requires_prompt(self) -> bool:
        return self is SegmentMode.OBJECT


class SegmentRequest(BaseModel):
    mode: SegmentMode = Field(description="Which selection pipeline to run.")

    image: str = Field(
        description="Base64-encoded image. A data: URL prefix is accepted.",
        repr=False,  # keeps multi-MB payloads out of logs and tracebacks
    )

    prompt: str | None = Field(
        default=None,
        max_length=200,
        description="What to select. Required for mode=object, ignored otherwise.",
    )

    refine_edges: bool = Field(
        default=True,
        description=(
            "Snap the mask boundary to the image's own edges. Adds roughly "
            "50ms and materially improves hair and foliage."
        ),
    )

    grow: int = Field(
        default=0,
        ge=-50,
        le=50,
        description="Pixels to grow (positive) or shrink (negative) the mask.",
    )

    feather: float = Field(
        default=0.0,
        ge=0.0,
        le=50.0,
        description="Gaussian softening radius applied to the mask edge.",
    )

    output: str = Field(default="png", pattern="^(png)$")

    @field_validator("prompt")
    @classmethod
    def _clean_prompt(cls, value: str | None) -> str | None:
        if value is None:
            return None
        cleaned = value.strip()
        return cleaned or None

    @model_validator(mode="after")
    def _prompt_matches_mode(self) -> "SegmentRequest":
        if self.mode.requires_prompt and not self.prompt:
            raise ValueError("mode=object requires a prompt")
        return self


class SegmentResponse(BaseModel):
    mask: str = Field(
        description="Base64 PNG, 8-bit greyscale, where 255 is fully selected.",
        repr=False,
    )
    width: int
    height: int

    score: float = Field(
        description="Model confidence in this selection, 0..1.",
        ge=0.0,
        le=1.0,
    )
    coverage: float = Field(
        description="Fraction of the frame selected, 0..1.",
        ge=0.0,
        le=1.0,
    )
    box: list[float] | None = Field(
        default=None,
        description="Normalised (left, top, right, bottom) of the selection.",
    )

    mode: SegmentMode
    prompt: str | None = None
    source: str = Field(description="Which engines produced this mask.")
    elapsed_ms: int
