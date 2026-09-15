"""Serialised GPU execution.

FastAPI serves requests concurrently on an event loop; the models here are
synchronous, CPU/GPU-bound torch code. Running them on the loop would
block every other request including health checks, and running them on
the default threadpool would let several forward passes hit one GPU at
once — which does not go faster, it goes slower and sometimes runs out
of VRAM.

So: one bounded executor, sized to the number of GPUs, with an explicit
queue limit and timeout.
"""

from __future__ import annotations

import asyncio
import logging
import time
from concurrent.futures import ThreadPoolExecutor
from typing import Any, Callable, TypeVar

from app.config import get_settings

log = logging.getLogger(__name__)

T = TypeVar("T")


class GpuBusy(RuntimeError):
    """The queue is full. Answered as 503 with a Retry-After, so a client
    backs off instead of piling on."""


class GpuTimeout(RuntimeError):
    """Inference exceeded its wall-clock budget."""


class GpuPool:
    """Runs blocking inference off the event loop, one job at a time."""

    def __init__(self) -> None:
        settings = get_settings()
        self._executor = ThreadPoolExecutor(
            max_workers=settings.gpu_workers,
            thread_name_prefix="gpu",
        )
        self._max_queue = settings.max_queue_depth
        self._timeout = settings.inference_timeout_s
        # Counts jobs submitted-but-not-finished. Incremented before
        # submission so the depth check sees work that is queued as well
        # as work that is running.
        self._inflight = 0
        self._lock = asyncio.Lock()

    @property
    def inflight(self) -> int:
        return self._inflight

    async def run(
        self,
        fn: Callable[..., T],
        *args: Any,
        label: str = "inference",
        **kwargs: Any,
    ) -> T:
        """Schedules [fn] on the GPU executor and awaits its result.

        Raises [GpuBusy] when the queue is saturated and [GpuTimeout] when
        the job overruns. Both are preferable to an open-ended wait: the
        mobile client has its own timeout, and a request the user has
        already given up on should not keep holding the GPU.
        """
        async with self._lock:
            if self._inflight >= self._max_queue:
                raise GpuBusy(
                    f"{self._inflight} jobs already queued; try again shortly"
                )
            self._inflight += 1

        started = time.perf_counter()
        loop = asyncio.get_running_loop()
        try:
            future = loop.run_in_executor(
                self._executor, lambda: fn(*args, **kwargs)
            )
            result = await asyncio.wait_for(future, timeout=self._timeout)
        except asyncio.TimeoutError as exc:
            log.error("%s exceeded %.0fs budget", label, self._timeout)
            raise GpuTimeout(f"{label} timed out after {self._timeout:.0f}s") from exc
        finally:
            async with self._lock:
                self._inflight -= 1

        log.info("%s finished in %.2fs", label, time.perf_counter() - started)
        return result

    def shutdown(self) -> None:
        # Not cancelling in-flight futures: a forward pass mid-CUDA-kernel
        # cannot be interrupted cleanly, and letting it finish avoids
        # leaving the device in a bad state.
        self._executor.shutdown(wait=True, cancel_futures=False)


_pool: GpuPool | None = None


def get_pool() -> GpuPool:
    """Process-wide pool. Created on first use so it binds to the running
    event loop rather than to import order."""
    global _pool
    if _pool is None:
        _pool = GpuPool()
    return _pool


def shutdown_pool() -> None:
    global _pool
    if _pool is not None:
        _pool.shutdown()
        _pool = None
