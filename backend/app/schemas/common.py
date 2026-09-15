"""Shared response shapes."""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field


class EngineStatus(BaseModel):
    configured: bool = Field(
        description="Weights and packages are present on this deployment."
    )
    loaded: bool = Field(description="Model is in memory and ready.")
    error: str | None = Field(
        default=None, description="Why the last load attempt failed."
    )


class HealthResponse(BaseModel):
    """What the mobile client polls before offering AI features.

    `status` is the single field clients branch on; everything else is
    for an operator reading the endpoint by hand.
    """

    status: Literal["ok", "degraded"] = Field(
        description=(
            "'ok' when every capability is servable; 'degraded' when the "
            "service is up but at least one engine is unavailable."
        )
    )
    version: str
    engines: dict[str, EngineStatus]
    capabilities: list[str] = Field(
        description="Segment modes this deployment can currently serve."
    )
    device: dict[str, object]
    queue_depth: int


class ErrorResponse(BaseModel):
    detail: str
