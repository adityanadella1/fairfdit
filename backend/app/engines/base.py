"""Shared lifecycle for every model wrapper.

The three engines wrap very different repositories, but they all have the
same shape: expensive to construct, cheap to call, and unusable if their
weights are missing. [Engine] encodes that once so each subclass only has
to say how to build its model and how to run it.
"""

from __future__ import annotations

import logging
import threading
import time
from abc import ABC, abstractmethod
from typing import Any

log = logging.getLogger(__name__)


class EngineUnavailable(RuntimeError):
    """The engine cannot run — weights absent, package not installed, or
    loading failed. Distinct from an inference error so the API can answer
    503 (fix the deployment) rather than 500 (fix the code)."""


class Engine(ABC):
    """Lazily-loaded, thread-safe wrapper around one upstream model.

    Loading is deferred to first use so the service starts in seconds and
    a machine that only ever serves `/v1/remove` never pays for SAM 2's
    weights. `eager_load` in settings flips this for deployments that
    prefer a slow boot and a fast first request.
    """

    #: Human name used in logs and the health payload.
    name: str = "engine"

    def __init__(self) -> None:
        self._model: Any | None = None
        # A lock, not just a None check: two requests arriving together on
        # a cold engine would otherwise both load the weights, doubling
        # peak VRAM at exactly the worst moment.
        self._lock = threading.Lock()
        self._load_error: str | None = None

    # --- Subclass contract ---------------------------------------------

    @abstractmethod
    def _build(self) -> Any:
        """Constructs and returns the underlying model. Called at most
        once. Raise [EngineUnavailable] if prerequisites are missing."""

    @abstractmethod
    def is_configured(self) -> bool:
        """True if the weights and packages this engine needs are present.
        Checked without loading anything, so health can report it."""

    # --- Lifecycle -------------------------------------------------------

    @property
    def is_loaded(self) -> bool:
        return self._model is not None

    @property
    def load_error(self) -> str | None:
        return self._load_error

    def model(self) -> Any:
        """The loaded model, building it on first call.

        A previous failure is cached and re-raised rather than retried:
        missing weights will still be missing on the next request, and
        retrying a 30-second load on every call turns a misconfiguration
        into an outage.
        """
        if self._model is not None:
            return self._model

        with self._lock:
            if self._model is not None:
                return self._model
            if self._load_error is not None:
                raise EngineUnavailable(self._load_error)

            started = time.perf_counter()
            try:
                log.info("loading %s…", self.name)
                self._model = self._build()
            except EngineUnavailable as exc:
                self._load_error = str(exc)
                log.error("%s unavailable: %s", self.name, exc)
                raise
            except Exception as exc:  # noqa: BLE001 - converted deliberately
                self._load_error = f"{self.name} failed to load: {exc}"
                log.exception("%s failed to load", self.name)
                raise EngineUnavailable(self._load_error) from exc

            log.info(
                "loaded %s in %.1fs", self.name, time.perf_counter() - started
            )
            return self._model

    def warmup(self) -> bool:
        """Loads now if possible. Returns whether the engine is ready, and
        never raises — a warmup failure must not stop the service from
        booting and serving the features that do work."""
        if not self.is_configured():
            log.warning("%s is not configured; skipping warmup", self.name)
            return False
        try:
            self.model()
            return True
        except EngineUnavailable:
            return False

    def status(self) -> dict[str, object]:
        """Health-endpoint view of this engine."""
        return {
            "configured": self.is_configured(),
            "loaded": self.is_loaded,
            "error": self._load_error,
        }

    def unload(self) -> None:
        """Drops the model and frees its VRAM. Here for completeness and
        for tests; the service does not swap models at runtime."""
        with self._lock:
            self._model = None
            self._load_error = None
        from app.utils.device import empty_cache

        empty_cache()
