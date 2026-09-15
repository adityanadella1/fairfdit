"""API contract tests.

These run without weights, a GPU or a network: they exercise validation,
routing, auth and error mapping, with the engines stubbed. That is
deliberate — the contract between the Flutter client and this service is
what breaks silently during a refactor, and it is exactly the part that
does not need a model to verify.
"""

from __future__ import annotations

import base64
import io

import numpy as np
import pytest
from fastapi.testclient import TestClient
from PIL import Image

from app.config import get_settings
from app.engines.mask_engine import MaskEngine
from app.main import create_app
from app.pipelines.base import NoSelectionFound


def png_base64(width: int = 64, height: int = 64) -> str:
    array = np.random.randint(0, 255, (height, width, 3), dtype=np.uint8)
    buffer = io.BytesIO()
    Image.fromarray(array).save(buffer, format="PNG")
    return base64.b64encode(buffer.getvalue()).decode("ascii")


@pytest.fixture
def client():
    with TestClient(create_app()) as test_client:
        yield test_client


@pytest.fixture
def stub_segment(monkeypatch):
    """Replaces the GPU pool with direct execution and the pipelines with
    a mask factory, so the route can be tested end to end in-process."""

    # Patched onto the class, so `self` arrives as the first argument.
    async def run_directly(self, fn, *args, label="", **kwargs):  # noqa: ANN001
        return fn(*args, **kwargs)

    from app.workers import gpu_pool

    monkeypatch.setattr(gpu_pool.GpuPool, "run", run_directly)

    def install(mask_factory):
        from app.api.deps import get_segmentation_service

        service = get_segmentation_service()
        for mode, pipeline in service._pipelines.items():  # noqa: SLF001
            monkeypatch.setattr(
                pipeline, "run", lambda request, f=mask_factory: f(request)
            )

    return install


class TestHealth:
    def test_health_is_always_200(self, client):
        """A deployment missing an optional checkpoint is degraded, not
        unhealthy — returning an error status would take it out of a load
        balancer over a partial capability gap."""
        response = client.get("/v1/health")
        assert response.status_code == 200
        body = response.json()
        assert body["status"] in {"ok", "degraded"}
        assert set(body["engines"]) == {"sam2", "grounding_dino", "lama"}

    def test_health_reports_capabilities_as_a_list(self, client):
        assert isinstance(client.get("/v1/health").json()["capabilities"], list)

    def test_ready_is_cheap_and_unauthenticated(self, client):
        assert client.get("/v1/ready").json() == {"ready": True}

    def test_root_points_at_the_docs(self, client):
        assert client.get("/").json()["health"] == "/v1/health"


class TestSegmentValidation:
    def test_object_mode_requires_a_prompt(self, client):
        response = client.post(
            "/v1/segment", json={"mode": "object", "image": png_base64()}
        )
        assert response.status_code == 422
        assert "prompt" in response.text

    def test_subject_mode_needs_no_prompt(self, client, stub_segment):
        stub_segment(lambda req: MaskEngine.from_box(64, 64, (0.2, 0.2, 0.8, 0.8)))
        response = client.post(
            "/v1/segment", json={"mode": "subject", "image": png_base64()}
        )
        assert response.status_code == 200

    def test_unknown_mode_is_rejected(self, client):
        response = client.post(
            "/v1/segment", json={"mode": "unicorn", "image": png_base64()}
        )
        assert response.status_code == 422

    def test_malformed_image_is_a_400(self, client):
        response = client.post(
            "/v1/segment", json={"mode": "subject", "image": "not-base64!!"}
        )
        assert response.status_code == 400
        assert "base64" in response.json()["detail"]

    def test_whitespace_prompt_is_treated_as_absent(self, client):
        response = client.post(
            "/v1/segment",
            json={"mode": "object", "image": png_base64(), "prompt": "   "},
        )
        assert response.status_code == 422

    @pytest.mark.parametrize("grow", [-51, 51])
    def test_grow_is_bounded(self, client, grow):
        response = client.post(
            "/v1/segment",
            json={"mode": "subject", "image": png_base64(), "grow": grow},
        )
        assert response.status_code == 422


class TestSegmentResponse:
    def test_mask_comes_back_at_the_requested_size(self, client, stub_segment):
        """The client composites the mask against the image it sent, so
        the response must match that geometry whatever resolution
        inference actually ran at."""
        stub_segment(
            # Deliberately a different size from the request, mimicking
            # inference at a reduced working resolution.
            lambda req: MaskEngine.from_box(32, 32, (0.1, 0.1, 0.9, 0.9))
        )
        response = client.post(
            "/v1/segment",
            json={"mode": "subject", "image": png_base64(200, 150)},
        )
        body = response.json()
        assert (body["width"], body["height"]) == (200, 150)

    def test_response_carries_every_contract_field(self, client, stub_segment):
        stub_segment(lambda req: MaskEngine.from_box(64, 64, (0.2, 0.2, 0.8, 0.8)))
        body = client.post(
            "/v1/segment", json={"mode": "subject", "image": png_base64()}
        ).json()
        assert set(body) >= {
            "mask", "width", "height", "score", "coverage",
            "box", "mode", "source", "elapsed_ms",
        }

    def test_mask_decodes_as_greyscale_png(self, client, stub_segment):
        stub_segment(lambda req: MaskEngine.from_box(64, 64, (0.25, 0.25, 0.75, 0.75)))
        body = client.post(
            "/v1/segment", json={"mode": "subject", "image": png_base64()}
        ).json()
        decoded = Image.open(io.BytesIO(base64.b64decode(body["mask"])))
        assert decoded.mode == "L"

    def test_nothing_found_is_404_not_500(self, client, stub_segment):
        """The pipeline ran correctly and there is no dog in the photo.
        That is an answer, not a failure."""
        def raise_not_found(_request):
            raise NoSelectionFound("no 'dog' was found in this image")

        stub_segment(raise_not_found)
        response = client.post(
            "/v1/segment",
            json={"mode": "object", "image": png_base64(), "prompt": "dog"},
        )
        assert response.status_code == 404
        assert "dog" in response.json()["detail"]


class TestRemoveValidation:
    def test_requires_both_image_and_mask(self, client):
        response = client.post("/v1/remove", json={"image": png_base64()})
        assert response.status_code == 422

    def test_malformed_mask_is_a_400(self, client):
        response = client.post(
            "/v1/remove", json={"image": png_base64(), "mask": "@@@"}
        )
        assert response.status_code == 400

    @pytest.mark.parametrize("dilate", [-1, 65])
    def test_dilate_is_bounded(self, client, dilate):
        response = client.post(
            "/v1/remove",
            json={"image": png_base64(), "mask": png_base64(), "dilate": dilate},
        )
        assert response.status_code == 422


class TestAuth:
    def test_key_is_required_once_configured(self, client, monkeypatch):
        settings = get_settings()
        monkeypatch.setattr(settings, "api_key", "secret-value")

        assert client.post(
            "/v1/segment", json={"mode": "subject", "image": png_base64()}
        ).status_code == 401

        # Health stays open — it is what clients poll to decide whether
        # to offer AI features at all.
        assert client.get("/v1/health").status_code == 200

    def test_correct_key_passes_the_gate(self, client, monkeypatch, stub_segment):
        settings = get_settings()
        monkeypatch.setattr(settings, "api_key", "secret-value")
        stub_segment(lambda req: MaskEngine.from_box(64, 64, (0.2, 0.2, 0.8, 0.8)))

        response = client.post(
            "/v1/segment",
            json={"mode": "subject", "image": png_base64()},
            headers={"X-API-Key": "secret-value"},
        )
        assert response.status_code == 200

    def test_no_key_configured_means_no_gate(self, client, stub_segment):
        stub_segment(lambda req: MaskEngine.from_box(64, 64, (0.2, 0.2, 0.8, 0.8)))
        assert client.post(
            "/v1/segment", json={"mode": "subject", "image": png_base64()}
        ).status_code == 200


class TestClientContract:
    def test_modes_match_the_flutter_enum(self, client):
        """These strings are the wire contract with AiMaskMode in
        lib/models/mask_state.dart. Renaming one here silently breaks
        every existing saved project that references it."""
        from app.schemas.segment import SegmentMode

        assert {m.value for m in SegmentMode} == {
            "subject", "person", "object", "background", "sky",
        }

    def test_timing_header_is_present(self, client):
        response = client.get("/v1/health")
        assert "X-Process-Time-Ms" in response.headers
