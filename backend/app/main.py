"""Application entry point.

    uvicorn app.main:app --host 0.0.0.0 --port 8000

Deliberately thin: it wires settings, logging, middleware, error handlers
and routers together and owns nothing else. Every behaviour lives in the
layer that owns it.
"""

from __future__ import annotations

import logging
import sys
import time
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware

from app.api.errors import register_exception_handlers
from app.api.v1 import health, remove, segment
from app.config import get_settings
from app.logging_config import configure_logging

log = logging.getLogger(__name__)


def _install_vendor_path() -> None:
    """Puts the extracted LaMa inference code on the import path.

    LaMa ships no package, so `scripts/fetch_vendor.py` extracts the
    inference subset of `saicinpainting/` into `backend/vendor/`. This is
    the only place that knows about it — nothing else imports through a
    path hack.
    """
    vendor = get_settings().vendor_dir
    if vendor.exists() and str(vendor) not in sys.path:
        sys.path.insert(0, str(vendor))
        log.debug("vendor path: %s", vendor)


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = get_settings()
    configure_logging(settings.log_level, settings.log_json)
    _install_vendor_path()

    log.info("%s %s starting", settings.app_name, settings.version)

    from app.engines.registry import engine_status, warmup_all
    from app.utils.device import describe_device

    log.info("device: %s", describe_device())

    if settings.eager_load:
        warmup_all()
    else:
        # Report what *could* run without paying to load it, so a missing
        # checkpoint shows up in the boot log rather than in the first
        # user-facing 503.
        for name, status in engine_status().items():
            log.info(
                "engine %-16s configured=%s", name, status["configured"]
            )

    yield

    from app.workers.gpu_pool import shutdown_pool

    shutdown_pool()
    log.info("shutdown complete")


def create_app() -> FastAPI:
    settings = get_settings()

    app = FastAPI(
        title=settings.app_name,
        version=settings.version,
        summary="AI masking and object removal for the FairEdit photo editor.",
        description=(
            "Selection masks from SAM 2 and Grounding DINO, and object "
            "removal from LaMa, behind one HTTP contract.\n\n"
            "All three upstream projects are used for inference only and "
            "are wrapped in engine classes — no route touches them directly."
        ),
        lifespan=lifespan,
        docs_url="/docs",
        openapi_url="/openapi.json",
    )

    if settings.cors_origins:
        app.add_middleware(
            CORSMiddleware,
            allow_origins=settings.cors_origins,
            allow_credentials=False,
            allow_methods=["GET", "POST"],
            allow_headers=["Content-Type", "X-API-Key"],
        )

    @app.middleware("http")
    async def timing_header(request: Request, call_next):
        """Stamps every response with its server-side duration.

        Inference latency varies by an order of magnitude with image size
        and mode; having the number on the response is what makes a
        "the app feels slow" report diagnosable from the client side.
        """
        started = time.perf_counter()
        response = await call_next(request)
        elapsed_ms = (time.perf_counter() - started) * 1000
        response.headers["X-Process-Time-Ms"] = f"{elapsed_ms:.0f}"
        return response

    register_exception_handlers(app)

    app.include_router(health.router)
    app.include_router(segment.router)
    app.include_router(remove.router)

    @app.get("/", include_in_schema=False)
    async def root() -> dict[str, str]:
        return {
            "service": settings.app_name,
            "version": settings.version,
            "docs": "/docs",
            "health": "/v1/health",
        }

    return app


app = create_app()
