"""Single source of engine instances.

Engines hold GPU weights, so exactly one of each must exist per process.
Constructing them here — rather than letting pipelines instantiate their
own — is what keeps that true, and gives startup and health one place to
ask about all three.
"""

from __future__ import annotations

import logging
from functools import lru_cache

from app.engines.grounding_engine import GroundingEngine
from app.engines.lama_engine import LamaEngine
from app.engines.sam2_engine import Sam2Engine

log = logging.getLogger(__name__)


@lru_cache(maxsize=1)
def sam2_engine() -> Sam2Engine:
    return Sam2Engine()


@lru_cache(maxsize=1)
def grounding_engine() -> GroundingEngine:
    return GroundingEngine()


@lru_cache(maxsize=1)
def lama_engine() -> LamaEngine:
    return LamaEngine()


def all_engines() -> dict[str, object]:
    return {
        "sam2": sam2_engine(),
        "grounding_dino": grounding_engine(),
        "lama": lama_engine(),
    }


def warmup_all() -> dict[str, bool]:
    """Loads every configured engine.

    Failures are recorded, not raised: a deployment with LaMa weights but
    no Grounding DINO checkpoint should still serve Select Subject and AI
    Remove rather than refusing to start.
    """
    results: dict[str, bool] = {}
    for name, engine in all_engines().items():
        results[name] = engine.warmup()  # type: ignore[attr-defined]
    ready = [name for name, ok in results.items() if ok]
    log.info("engines ready: %s", ", ".join(ready) or "none")
    return results


def engine_status() -> dict[str, dict[str, object]]:
    return {
        name: engine.status()  # type: ignore[attr-defined]
        for name, engine in all_engines().items()
    }
