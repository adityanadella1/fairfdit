"""Decoding, encoding and resizing at the service boundary.

Every byte that enters or leaves the API passes through here, so the
rules about orientation, colour space, alpha and size limits are stated
once.
"""

from __future__ import annotations

import base64
import binascii
import io
import logging

import numpy as np
from PIL import Image, ImageOps, UnidentifiedImageError

from app.config import get_settings

log = logging.getLogger(__name__)

# Pillow refuses very large images by default as a decompression-bomb
# guard. The service enforces its own byte limit before decoding, so
# raising this only affects legitimately large photos.
Image.MAX_IMAGE_PIXELS = 200_000_000


class ImageDecodeError(ValueError):
    """Input that is not a usable image. Surfaces as HTTP 400."""


def decode_base64_image(data: str, *, field: str = "image") -> np.ndarray:
    """Decodes a base64 payload to an HWC uint8 RGB array.

    EXIF orientation is applied here rather than ignored: a phone photo is
    routinely stored rotated with an orientation tag, and a mask computed
    on the unrotated pixels would come back sideways relative to what the
    user saw.
    """
    settings = get_settings()

    # Tolerate a data URL prefix — easy for a client to send by accident
    # and pointless to reject over.
    if data.startswith("data:"):
        _, _, data = data.partition(",")

    try:
        raw = base64.b64decode(data, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise ImageDecodeError(f"{field} is not valid base64") from exc

    if not raw:
        raise ImageDecodeError(f"{field} is empty")
    if len(raw) > settings.max_upload_bytes:
        raise ImageDecodeError(
            f"{field} is {len(raw) / 1024**2:.1f} MB, over the "
            f"{settings.max_upload_mb:.0f} MB limit"
        )

    try:
        with Image.open(io.BytesIO(raw)) as img:
            img = ImageOps.exif_transpose(img)
            return np.array(img.convert("RGB"))
    except (UnidentifiedImageError, OSError) as exc:
        raise ImageDecodeError(f"{field} could not be decoded as an image") from exc


def decode_base64_mask(data: str, *, field: str = "mask") -> np.ndarray:
    """Decodes a mask payload to an HW uint8 array in 0..255.

    Accepts anything Pillow can open. An RGBA mask is flattened to
    luminance rather than to its alpha channel, because clients that
    render a mask for display (as the Flutter app does) write coverage
    into the colour channels and leave alpha opaque.
    """
    rgb = decode_base64_image(data, field=field)
    return np.asarray(
        Image.fromarray(rgb).convert("L"),
        dtype=np.uint8,
    )


def encode_png(array: np.ndarray) -> str:
    """Encodes an HW (mask) or HWC (image) uint8 array as base64 PNG."""
    if array.dtype != np.uint8:
        array = np.clip(array, 0, 255).astype(np.uint8)

    mode = "L" if array.ndim == 2 else "RGB"
    buffer = io.BytesIO()
    # compress_level 6 is the knee of the curve: near-maximum ratio at a
    # fraction of level 9's CPU, which matters when the response is a
    # multi-megabyte image and the GPU worker is the bottleneck.
    Image.fromarray(array, mode=mode).save(buffer, format="PNG", compress_level=6)
    return base64.b64encode(buffer.getvalue()).decode("ascii")


def fit_within(image: np.ndarray, max_dimension: int) -> tuple[np.ndarray, float]:
    """Downscales so the longest edge is at most [max_dimension].

    Returns the image and the scale that was applied, so the caller can
    map results back to the original geometry. Never upscales: feeding a
    model interpolated pixels invents detail it will then segment.
    """
    height, width = image.shape[:2]
    longest = max(height, width)
    if longest <= max_dimension:
        return image, 1.0

    scale = max_dimension / longest
    size = (max(1, round(width * scale)), max(1, round(height * scale)))
    resized = Image.fromarray(image).resize(size, Image.Resampling.LANCZOS)
    log.debug("resized %sx%s -> %sx%s", width, height, size[0], size[1])
    return np.asarray(resized), scale


def resize_mask(mask: np.ndarray, height: int, width: int) -> np.ndarray:
    """Resamples a mask to an exact size.

    Bilinear, not nearest: a mask upscaled with nearest neighbour gets
    staircased edges that are visible the moment it drives an exposure
    change. Soft edges are a feature here, not an artefact.
    """
    if mask.shape[:2] == (height, width):
        return mask
    resized = Image.fromarray(mask, mode="L").resize(
        (width, height), Image.Resampling.BILINEAR
    )
    return np.asarray(resized, dtype=np.uint8)
