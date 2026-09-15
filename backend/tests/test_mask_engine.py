"""MaskEngine is the one component every feature depends on and the only
one that can be tested without a GPU, weights or a network. These cover
the invariants the pipelines rely on."""

from __future__ import annotations

import numpy as np
import pytest

from app.engines.mask_engine import Mask, MaskEngine


def square_mask(size: int = 64, box: int = 20) -> Mask:
    """A centred filled square — an easy shape to reason about under
    morphology, where area changes are predictable."""
    data = np.zeros((size, size), dtype=np.float32)
    start = (size - box) // 2
    data[start : start + box, start : start + box] = 1.0
    return Mask(data=data, source="test")


class TestConstruction:
    def test_create_is_empty(self):
        mask = MaskEngine.create(10, 20)
        assert mask.shape == (10, 20)
        assert mask.is_empty()
        assert mask.coverage == 0.0

    def test_from_bool_array(self):
        source = np.zeros((8, 8), dtype=bool)
        source[2:6, 2:6] = True
        mask = MaskEngine.from_array(source)
        assert mask.data.dtype == np.float32
        assert mask.coverage == pytest.approx(16 / 64)

    def test_from_uint8_array_is_scaled(self):
        source = np.full((4, 4), 255, dtype=np.uint8)
        assert MaskEngine.from_array(source).coverage == pytest.approx(1.0)

    def test_singleton_batch_axis_is_squeezed(self):
        """SAM 2 returns (1, H, W) for a single prompt and (N, H, W) for
        several; the single case must not become a 3-D mask."""
        mask = MaskEngine.from_array(np.ones((1, 5, 7), dtype=np.float32))
        assert mask.shape == (5, 7)

    def test_rejects_unsqueezable_shape(self):
        with pytest.raises(ValueError, match="cannot interpret"):
            MaskEngine.from_array(np.ones((3, 4, 5)))

    def test_from_box_fills_the_rectangle(self):
        mask = MaskEngine.from_box(100, 100, (0.25, 0.25, 0.75, 0.75))
        assert mask.coverage == pytest.approx(0.25, abs=0.02)


class TestAlgebra:
    def test_add_is_union_and_stays_bounded(self):
        a = MaskEngine.create(10, 10, fill=0.6)
        b = MaskEngine.create(10, 10, fill=0.7)
        # Max, not sum: two overlapping soft masks must not clip to a
        # hard edge where they meet.
        assert MaskEngine.add(a, b).coverage == pytest.approx(0.7)

    def test_subtract_clamps_at_zero(self):
        a = MaskEngine.create(10, 10, fill=0.3)
        b = MaskEngine.create(10, 10, fill=0.8)
        assert MaskEngine.subtract(a, b).coverage == pytest.approx(0.0)

    def test_intersect_is_probabilistic(self):
        a = MaskEngine.create(10, 10, fill=0.5)
        b = MaskEngine.create(10, 10, fill=0.5)
        assert MaskEngine.intersect(a, b).coverage == pytest.approx(0.25)

    def test_invert_round_trips(self):
        mask = square_mask()
        assert MaskEngine.invert(MaskEngine.invert(mask)).coverage == pytest.approx(
            mask.coverage
        )

    def test_invert_is_the_background_pipeline(self):
        subject = square_mask(64, 20)
        background = MaskEngine.invert(subject)
        assert background.coverage == pytest.approx(1 - subject.coverage)

    def test_combining_mismatched_shapes_is_an_error(self):
        with pytest.raises(ValueError, match="shapes differ"):
            MaskEngine.add(MaskEngine.create(4, 4), MaskEngine.create(5, 5))

    def test_union_all_folds_detections(self):
        a = MaskEngine.create(20, 20)
        a.data[0:5, 0:5] = 1.0
        b = MaskEngine.create(20, 20)
        b.data[10:15, 10:15] = 1.0
        assert MaskEngine.union_all([a, b]).coverage == pytest.approx(50 / 400)

    def test_union_all_rejects_empty_input(self):
        with pytest.raises(ValueError):
            MaskEngine.union_all([])


class TestMorphology:
    def test_expand_grows_and_contract_shrinks(self):
        mask = square_mask()
        assert MaskEngine.expand(mask, 3).coverage > mask.coverage
        assert MaskEngine.contract(mask, 3).coverage < mask.coverage

    def test_expand_with_negative_pixels_contracts(self):
        """The API exposes one signed Refine slider, so the sign has to
        route correctly rather than clamping at zero."""
        mask = square_mask()
        assert MaskEngine.expand(mask, -3).coverage == pytest.approx(
            MaskEngine.contract(mask, 3).coverage
        )

    def test_zero_pixel_operations_are_identity(self):
        mask = square_mask()
        assert MaskEngine.expand(mask, 0).coverage == pytest.approx(mask.coverage)
        assert MaskEngine.feather(mask, 0).coverage == pytest.approx(mask.coverage)

    def test_feather_softens_the_edge_without_binarising(self):
        feathered = MaskEngine.feather(square_mask(), 4)
        interior = np.logical_and(feathered.data > 0.01, feathered.data < 0.99)
        assert interior.any(), "feather produced no partial coverage"

    def test_fill_holes_closes_an_interior_gap(self):
        mask = square_mask(64, 30)
        mask.data[30:34, 30:34] = 0.0  # punch a hole in the middle
        before = mask.coverage
        assert MaskEngine.fill_holes(mask).coverage > before

    def test_remove_holes_drops_specks(self):
        mask = square_mask(64, 20)
        mask.data[2, 2] = 1.0  # single-pixel speck far from the square
        cleaned = MaskEngine.remove_holes(mask, min_area=16)
        assert cleaned.data[2, 2] == 0.0
        assert cleaned.data[32, 32] == 1.0

    def test_keep_largest_component(self):
        mask = MaskEngine.create(40, 40)
        mask.data[0:10, 0:10] = 1.0   # 100 px
        mask.data[30:33, 30:33] = 1.0  # 9 px
        kept = MaskEngine.keep_largest_component(mask)
        assert kept.data[5, 5] == 1.0
        assert kept.data[31, 31] == 0.0

    def test_morphology_never_mutates_its_input(self):
        """Masks are cached and shared between pipeline stages; an
        in-place edit here would corrupt a caller's copy."""
        mask = square_mask()
        original = mask.data.copy()
        MaskEngine.expand(mask, 5)
        MaskEngine.feather(mask, 5)
        MaskEngine.fill_holes(mask)
        assert np.array_equal(mask.data, original)

    def test_provenance_survives_morphology(self):
        mask = Mask(data=square_mask().data, score=0.87, source="sam2")
        result = MaskEngine.feather(MaskEngine.expand(mask, 2), 2)
        assert result.score == pytest.approx(0.87)
        assert result.source.startswith("sam2")


class TestGeometry:
    def test_resize_changes_shape_and_keeps_coverage(self):
        mask = square_mask(64, 32)
        resized = MaskEngine.resize(mask, 128, 128)
        assert resized.shape == (128, 128)
        assert resized.coverage == pytest.approx(mask.coverage, abs=0.02)

    def test_bounding_box_is_normalised(self):
        mask = MaskEngine.from_box(100, 100, (0.2, 0.3, 0.6, 0.8))
        box = MaskEngine.bounding_box(mask)
        assert box == pytest.approx((0.2, 0.3, 0.6, 0.8), abs=0.02)

    def test_bounding_box_of_empty_mask_is_none(self):
        assert MaskEngine.bounding_box(MaskEngine.create(10, 10)) is None


class TestSerialisation:
    def test_serialize_shape(self):
        payload = MaskEngine.serialize(square_mask())
        assert set(payload) == {
            "mask", "width", "height", "score", "coverage", "box", "source",
        }
        assert isinstance(payload["mask"], str)

    def test_png_round_trips_through_base64(self):
        import base64
        import io

        from PIL import Image

        mask = square_mask(32, 16)
        decoded = Image.open(io.BytesIO(base64.b64decode(mask.to_png_base64())))
        restored = MaskEngine.from_array(np.array(decoded))
        assert restored.shape == mask.shape
        assert restored.coverage == pytest.approx(mask.coverage, abs=0.01)
