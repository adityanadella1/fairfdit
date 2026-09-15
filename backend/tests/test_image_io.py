"""The service boundary. Everything here is about refusing bad input
clearly rather than letting it reach a model."""

from __future__ import annotations

import base64
import io

import numpy as np
import pytest
from PIL import Image

from app.utils.image_io import (
    ImageDecodeError,
    decode_base64_image,
    decode_base64_mask,
    encode_png,
    fit_within,
    resize_mask,
)


def png_base64(array: np.ndarray, mode: str = "RGB") -> str:
    buffer = io.BytesIO()
    Image.fromarray(array, mode=mode).save(buffer, format="PNG")
    return base64.b64encode(buffer.getvalue()).decode("ascii")


class TestDecode:
    def test_round_trips_an_rgb_image(self):
        source = np.random.randint(0, 255, (32, 48, 3), dtype=np.uint8)
        decoded = decode_base64_image(png_base64(source))
        assert decoded.shape == (32, 48, 3)
        assert np.array_equal(decoded, source)

    def test_accepts_a_data_url_prefix(self):
        """Easy for a web client to send by accident and pointless to
        reject over."""
        source = np.zeros((8, 8, 3), dtype=np.uint8)
        payload = f"data:image/png;base64,{png_base64(source)}"
        assert decode_base64_image(payload).shape == (8, 8, 3)

    def test_greyscale_is_promoted_to_rgb(self):
        source = np.full((10, 10), 128, dtype=np.uint8)
        assert decode_base64_image(png_base64(source, mode="L")).shape == (10, 10, 3)

    def test_rejects_non_base64(self):
        with pytest.raises(ImageDecodeError, match="not valid base64"):
            decode_base64_image("this is not base64!!")

    def test_rejects_empty_payload(self):
        with pytest.raises(ImageDecodeError, match="empty"):
            decode_base64_image("")

    def test_rejects_non_image_bytes(self):
        payload = base64.b64encode(b"definitely not a png").decode()
        with pytest.raises(ImageDecodeError, match="could not be decoded"):
            decode_base64_image(payload)

    def test_error_names_the_offending_field(self):
        """A 400 that says which of image/mask was bad saves a debugging
        round trip on the client."""
        with pytest.raises(ImageDecodeError, match="mask"):
            decode_base64_image("!!!", field="mask")


class TestMaskDecode:
    def test_flattens_rgba_by_luminance_not_alpha(self):
        """Clients that render masks for display write coverage into the
        colour channels and leave alpha opaque — reading alpha would
        return a fully-selected mask every time."""
        rgba = np.zeros((8, 8, 4), dtype=np.uint8)
        rgba[..., :3] = 200
        rgba[..., 3] = 255
        buffer = io.BytesIO()
        Image.fromarray(rgba, mode="RGBA").save(buffer, format="PNG")
        payload = base64.b64encode(buffer.getvalue()).decode()

        mask = decode_base64_mask(payload)
        assert mask.shape == (8, 8)
        assert mask.mean() == pytest.approx(200, abs=2)


class TestResize:
    def test_fit_within_downscales_and_reports_scale(self):
        image = np.zeros((2000, 1000, 3), dtype=np.uint8)
        resized, scale = fit_within(image, 500)
        assert max(resized.shape[:2]) == 500
        assert scale == pytest.approx(0.25)

    def test_fit_within_never_upscales(self):
        """Interpolated pixels are invented detail the model will then
        segment, so growing a small image is worse than leaving it."""
        image = np.zeros((100, 80, 3), dtype=np.uint8)
        resized, scale = fit_within(image, 4096)
        assert resized.shape == image.shape
        assert scale == 1.0

    def test_fit_within_preserves_aspect_ratio(self):
        image = np.zeros((900, 300, 3), dtype=np.uint8)
        resized, _ = fit_within(image, 300)
        assert resized.shape[0] / resized.shape[1] == pytest.approx(3.0, abs=0.02)

    def test_resize_mask_hits_the_exact_size(self):
        mask = np.zeros((50, 50), dtype=np.uint8)
        assert resize_mask(mask, 137, 91).shape == (137, 91)

    def test_resize_mask_is_a_no_op_at_the_same_size(self):
        mask = np.full((10, 10), 7, dtype=np.uint8)
        assert resize_mask(mask, 10, 10) is mask


class TestEncode:
    def test_encodes_a_mask_as_greyscale(self):
        mask = np.full((16, 16), 128, dtype=np.uint8)
        decoded = Image.open(io.BytesIO(base64.b64decode(encode_png(mask))))
        assert decoded.mode == "L"
        assert decoded.size == (16, 16)

    def test_clips_and_casts_a_float_array(self):
        array = np.array([[-50.0, 300.0]], dtype=np.float32)
        decoded = np.array(
            Image.open(io.BytesIO(base64.b64decode(encode_png(array))))
        )
        assert decoded.tolist() == [[0, 255]]
