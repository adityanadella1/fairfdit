"""Request and response contracts for POST /v1/remove."""

from __future__ import annotations

from pydantic import BaseModel, Field


class RemoveRequest(BaseModel):
    image: str = Field(
        description="Base64-encoded source image.",
        repr=False,
    )
    mask: str = Field(
        description=(
            "Base64-encoded mask. Any Pillow-readable format; non-zero "
            "pixels mark what to remove. Resized to the image if needed."
        ),
        repr=False,
    )
    dilate: int = Field(
        default=8,
        ge=0,
        le=64,
        description=(
            "Pixels of margin added around the mask before inpainting. Some "
            "margin is necessary — a mask that traces an object exactly "
            "leaves its shadow and colour fringe behind for the model to "
            "rebuild the object from."
        ),
    )


class RemoveResponse(BaseModel):
    image: str = Field(
        description="Base64 PNG of the result, at the input's dimensions.",
        repr=False,
    )
    width: int
    height: int
    elapsed_ms: int
