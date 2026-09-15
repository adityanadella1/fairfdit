"""Domain errors to HTTP status codes, in one place.

Registered as exception handlers rather than caught in each route, so a
route body contains only its happy path and every failure of the same
kind answers identically.

    ImageDecodeError   400  the client sent something unusable
    NoSelectionFound   404  ran fine, found nothing — not an error
    EngineUnavailable  503  this deployment cannot serve that
    GpuBusy            503  overloaded, with Retry-After
    GpuTimeout         504  inference overran its budget
"""

from __future__ import annotations

import logging

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

from app.engines.base import EngineUnavailable
from app.pipelines.base import NoSelectionFound
from app.utils.image_io import ImageDecodeError
from app.workers.gpu_pool import GpuBusy, GpuTimeout

log = logging.getLogger(__name__)


def register_exception_handlers(app: FastAPI) -> None:
    @app.exception_handler(ImageDecodeError)
    async def _decode_error(_: Request, exc: ImageDecodeError) -> JSONResponse:
        return JSONResponse(status_code=400, content={"detail": str(exc)})

    @app.exception_handler(NoSelectionFound)
    async def _no_selection(_: Request, exc: NoSelectionFound) -> JSONResponse:
        # 404 rather than 422: the request was well-formed and processed
        # correctly, there is simply nothing matching in the image.
        return JSONResponse(status_code=404, content={"detail": str(exc)})

    @app.exception_handler(EngineUnavailable)
    async def _engine_unavailable(_: Request, exc: EngineUnavailable) -> JSONResponse:
        log.error("engine unavailable: %s", exc)
        return JSONResponse(status_code=503, content={"detail": str(exc)})

    @app.exception_handler(GpuBusy)
    async def _busy(_: Request, exc: GpuBusy) -> JSONResponse:
        return JSONResponse(
            status_code=503,
            content={"detail": str(exc)},
            headers={"Retry-After": "5"},
        )

    @app.exception_handler(GpuTimeout)
    async def _timeout(_: Request, exc: GpuTimeout) -> JSONResponse:
        return JSONResponse(status_code=504, content={"detail": str(exc)})

    @app.exception_handler(ValueError)
    async def _value_error(_: Request, exc: ValueError) -> JSONResponse:
        # A bare ValueError from deep in a pipeline is a bad argument the
        # schema did not catch, which makes it the client's input problem.
        return JSONResponse(status_code=400, content={"detail": str(exc)})
