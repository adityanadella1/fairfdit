"""LaMa, wrapped.

Reuses `saicinpainting.training.trainers.load_checkpoint` and the
repository's padding helper. LaMa has no published package, so
`scripts/fetch_vendor.py` extracts the inference subset of
`saicinpainting/` into `backend/vendor/` and puts it on the path — the
training loop, dataset code and evaluation harness are not copied.

Everything in this file is plumbing around a single forward pass:
resolution management, mask hygiene, and stitching the result back into
the original image.
"""

from __future__ import annotations

import logging

import cv2
import numpy as np

from app.config import get_settings
from app.engines.base import Engine, EngineUnavailable
from app.engines.mask_engine import Mask, MaskEngine
from app.utils.device import empty_cache, get_device

log = logging.getLogger(__name__)

#: LaMa's fast-Fourier convolutions require both dimensions to be a
#: multiple of 8. Upstream pads to this and crops afterwards.
PAD_MODULO = 8


class LamaEngine(Engine):
    """Mask-guided inpainting — the engine behind AI Remove."""

    name = "lama"

    def is_configured(self) -> bool:
        settings = get_settings()
        lama_dir = settings.resolved_lama_dir()
        if lama_dir is None:
            return False
        checkpoint = lama_dir / "models" / settings.lama_checkpoint_name
        if not ((lama_dir / "config.yaml").exists() and checkpoint.exists()):
            return False

        # Weights on disk are necessary but not sufficient. LaMa's import
        # chain reaches albumentations <1.0 -> imgaug -> numpy <2.0, which
        # cannot coexist with torch 2.x on Python 3.12+; a deployment can
        # therefore have every checkpoint in place and still be unable to
        # load the model.
        #
        # Checking the import here — as the SAM 2 and Grounding DINO
        # engines already do for their own packages — is what keeps
        # /v1/health honest. Without it the service advertises AI Remove
        # as available and then fails at request time, which reads to the
        # user as a broken feature rather than a missing one.
        return self._imports_cleanly()

    @staticmethod
    def _imports_cleanly() -> bool:
        """Probes the vendored package without loading any weights.

        The result is cached on the class: the import is comparatively
        slow, and it cannot change while the process is alive.
        """
        cached = getattr(LamaEngine, "_import_ok", None)
        if cached is not None:
            return cached

        try:
            import saicinpainting.training.trainers  # noqa: F401

            ok = True
        except Exception as exc:  # noqa: BLE001 - any failure means unusable
            log.warning("LaMa is installed but not importable: %s", exc)
            ok = False

        LamaEngine._import_ok = ok
        return ok

    def _build(self):
        try:
            from omegaconf import OmegaConf
            from saicinpainting.training.trainers import load_checkpoint
        except ImportError as exc:
            raise EngineUnavailable(
                "saicinpainting is not on the path — run scripts/fetch_vendor.py"
            ) from exc

        settings = get_settings()
        lama_dir = settings.resolved_lama_dir()
        if lama_dir is None:
            raise EngineUnavailable(
                "LaMa weights are missing — run scripts/download_weights.py"
            )

        config = OmegaConf.load(lama_dir / "config.yaml")
        # The released config describes a training run. Three overrides
        # turn it into an inference config; without them the trainer tries
        # to build optimisers, loggers and a visualiser at construction.
        config.training_model.predict_only = True
        config.visualizer.kind = "noop"
        config.training_model.pop("losses", None)

        checkpoint = lama_dir / "models" / settings.lama_checkpoint_name
        log.info("building LaMa from %s", checkpoint)

        # strict=False because the training checkpoint carries loss-network
        # weights (a VGG perceptual net, a discriminator) that the
        # inference graph has no slots for.
        model = load_checkpoint(
            config, str(checkpoint), strict=False, map_location="cpu"
        )
        model.freeze()
        return model.to(get_device()).eval()

    # --- Inference -----------------------------------------------------------

    def inpaint(
        self,
        image: np.ndarray,
        mask: Mask,
        *,
        dilate: int = 8,
    ) -> np.ndarray:
        """Reconstructs the masked region of [image].

        Returns a full-resolution RGB array. The mask is dilated first
        because LaMa needs a margin of certainly-removed pixels around the
        object: a mask that traces an object exactly leaves its shadow and
        colour fringe behind, and the network happily reconstructs the
        object *from* them.
        """
        model = self.model()
        settings = get_settings()
        original_h, original_w = image.shape[:2]

        working = MaskEngine.resize(mask, original_h, original_w)
        if dilate > 0:
            working = MaskEngine.expand(working, dilate)

        # LaMa's receptive field is tied to the scale it was trained at,
        # so a 4K image is downscaled for the pass and the result is
        # composited back at full size. Running it native produces a
        # visibly blurry, low-frequency fill.
        scale = 1.0
        longest = max(original_h, original_w)
        if longest > settings.lama_max_dimension:
            scale = settings.lama_max_dimension / longest
            infer_w = max(1, round(original_w * scale))
            infer_h = max(1, round(original_h * scale))
            infer_image = cv2.resize(
                image, (infer_w, infer_h), interpolation=cv2.INTER_AREA
            )
            infer_mask = MaskEngine.resize(working, infer_h, infer_w)
        else:
            infer_image = image
            infer_mask = working

        result = self._forward(model, infer_image, infer_mask)

        if scale != 1.0:
            result = cv2.resize(
                result, (original_w, original_h), interpolation=cv2.INTER_LANCZOS4
            )

        composited = self._composite(image, result, working)
        empty_cache()
        return composited

    def _forward(self, model, image: np.ndarray, mask: Mask) -> np.ndarray:
        """One padded forward pass. Returns RGB uint8 at the input size."""
        import torch

        height, width = image.shape[:2]

        image_t = torch.from_numpy(image).permute(2, 0, 1).float().div_(255.0)
        # Binary, not soft: LaMa's input is "is this pixel known or not",
        # and a 0.5 there means half-known, which the network reads as
        # noisy signal rather than as a feathered edge.
        mask_t = torch.from_numpy((mask.data > 0.5).astype(np.float32))[None]

        image_t, pad = self._pad_to_modulo(image_t)
        mask_t, _ = self._pad_to_modulo(mask_t)

        device = get_device()
        batch = {
            "image": image_t[None].to(device),
            "mask": mask_t[None].to(device),
        }

        with torch.inference_mode():
            batch = model(batch)
            output = batch["inpainted"][0]

        output = output.permute(1, 2, 0).clamp(0, 1).mul(255).byte().cpu().numpy()
        pad_h, pad_w = pad
        if pad_h or pad_w:
            output = output[: height if pad_h else None, : width if pad_w else None]
        return output

    @staticmethod
    def _pad_to_modulo(tensor: "torch.Tensor") -> tuple["torch.Tensor", tuple[int, int]]:
        """Pads the trailing two dimensions up to a multiple of 8.

        Symmetric padding rather than zeros: a black border would read as
        real content at the frame edge and bleed dark pixels into the fill
        for any mask that touches it.
        """
        import torch

        height, width = tensor.shape[-2:]
        pad_h = (PAD_MODULO - height % PAD_MODULO) % PAD_MODULO
        pad_w = (PAD_MODULO - width % PAD_MODULO) % PAD_MODULO
        if not pad_h and not pad_w:
            return tensor, (0, 0)
        padded = torch.nn.functional.pad(
            tensor[None], (0, pad_w, 0, pad_h), mode="replicate"
        )[0]
        return padded, (pad_h, pad_w)

    @staticmethod
    def _composite(
        original: np.ndarray, inpainted: np.ndarray, mask: Mask
    ) -> np.ndarray:
        """Keeps original pixels outside the mask.

        LaMa regenerates the whole frame, and its reconstruction of the
        untouched 95% is very slightly softer than the source. Compositing
        through a feathered mask means the edit is confined to what the
        user actually brushed, with no seam where the two meet.
        """
        alpha = MaskEngine.feather(mask, 2.0).data[..., None]
        blended = original.astype(np.float32) * (1 - alpha)
        blended += inpainted.astype(np.float32) * alpha
        return np.clip(blended, 0, 255).astype(np.uint8)
