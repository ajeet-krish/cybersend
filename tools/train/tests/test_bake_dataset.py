"""Unit tests for the letterbox bake (hold-bake): geometry, boxes, round trip.

Run from tools/train:

    uv run python -m unittest discover -s tests -v

The critical assertions are:

  * the bake geometry is byte-consistent with the harness letterbox in
    tools/eval/src/preprocess.ts (centered pads, JavaScript half-up rounding),
  * a baked image fed back through a faithful port of the harness letterbox is
    an exact identity (round trip, no resampling, no pad changes),
  * boxes scale and pad with their image, clip to the canvas, and degenerate
    boxes are dropped and counted,
  * baking is idempotent (a second bake changes neither image nor annotation
    bytes) and verify() enforces the baked invariants plus category id 1.
"""

from __future__ import annotations

import json
import math
import shutil
import tempfile
import unittest
from collections import Counter
from pathlib import Path
from typing import Any

import numpy as np
from PIL import Image

from hold_train.bake_dataset import (
    DEFAULT_IMAGE_SIZE,
    DEFAULT_PAD_VALUE,
    bake,
    js_round,
    letterbox_geometry,
    letterbox_image,
    map_box_to_letterbox,
    verify,
)
from hold_train.common import SINGLE_CLASS_ID, sha256_file

SOURCE_WIDTH = 800
SOURCE_HEIGHT = 450
# 800x450 letterboxes with scale 0.8, content 640x360, pad (0, 140).
EXPECTED_SCALE = 0.8
EXPECTED_PAD_X = 0
EXPECTED_PAD_Y = 140


def harness_js_round(value: float) -> int:
    """Independent JavaScript Math.round port used to cross-check js_round."""
    return math.floor(value + 0.5)


def harness_geometry(width: int, height: int, size: int) -> tuple[float, int, int]:
    """Faithful port of preprocess.ts letterboxGeometryFor: (scale, pad_x, pad_y)."""
    scale = min(size / width, size / height)
    content_width = max(1, harness_js_round(width * scale))
    content_height = max(1, harness_js_round(height * scale))
    return scale, math.floor((size - content_width) / 2), math.floor((size - content_height) / 2)


def harness_content_size(width: int, height: int, size: int) -> tuple[int, int]:
    """Content size the harness would write, per preprocess.ts letterboxRgba."""
    scale = min(size / width, size / height)
    return max(1, harness_js_round(width * scale)), max(1, harness_js_round(height * scale))


def harness_letterbox_rgba(
    rgba: np.ndarray, size: int = DEFAULT_IMAGE_SIZE, pad_value: int = DEFAULT_PAD_VALUE
) -> np.ndarray:
    """Vectorized port of preprocess.ts letterboxRgba; returns size x size x 3 uint8."""
    source_height, source_width = rgba.shape[0], rgba.shape[1]
    scale, pad_x, pad_y = harness_geometry(source_width, source_height, size)
    content_width, content_height = harness_content_size(source_width, source_height, size)

    canvas = np.full((size, size, 3), pad_value, dtype=np.uint8)
    rows = np.arange(content_height, dtype=np.float64)
    columns = np.arange(content_width, dtype=np.float64)
    source_y = (rows - pad_y + 0.5) / scale - 0.5
    source_x = (columns - pad_x + 0.5) / scale - 0.5
    y0 = np.floor(source_y)
    x0 = np.floor(source_x)
    fy = source_y - y0
    fx = source_x - x0
    y0c = np.clip(y0.astype(np.int64), 0, source_height - 1)
    y1c = np.clip(y0.astype(np.int64) + 1, 0, source_height - 1)
    x0c = np.clip(x0.astype(np.int64), 0, source_width - 1)
    x1c = np.clip(x0.astype(np.int64) + 1, 0, source_width - 1)

    top_left = rgba[y0c][:, x0c][:, :, :3].astype(np.float64)
    top_right = rgba[y0c][:, x1c][:, :, :3].astype(np.float64)
    bottom_left = rgba[y1c][:, x0c][:, :, :3].astype(np.float64)
    bottom_right = rgba[y1c][:, x1c][:, :, :3].astype(np.float64)
    top = top_left + (top_right - top_left) * fx[None, :, None]
    bottom = bottom_left + (bottom_right - bottom_left) * fx[None, :, None]
    # JavaScript Math.round on the non-negative pixel range is floor(v + 0.5).
    values = np.floor(top + (bottom - top) * fy[:, None, None] + 0.5).astype(np.uint8)

    canvas[pad_y : pad_y + content_height, pad_x : pad_x + content_width] = values
    return canvas


def synthetic_source(width: int = SOURCE_WIDTH, height: int = SOURCE_HEIGHT) -> Image.Image:
    """Deterministic colorful source image (no external files needed)."""
    rows = np.arange(height, dtype=np.uint16)[:, None]
    columns = np.arange(width, dtype=np.uint16)[None, :]
    array = np.stack(
        [
            (columns * 7 + rows * 3) % 256,
            (rows * 5 + columns) % 256,
            (columns + rows * 11) % 256,
        ],
        axis=-1,
    ).astype(np.uint8)
    return Image.fromarray(array, "RGB")


def annotation(annotation_id: int, bbox: list[float]) -> dict[str, Any]:
    """One single-class COCO annotation with category id 1."""
    return {
        "id": annotation_id,
        "image_id": 1,
        "category_id": SINGLE_CLASS_ID,
        "bbox": bbox,
        "area": round(bbox[2] * bbox[3], 2),
        "iscrowd": 0,
    }


def write_split(
    dataset_dir: Path,
    split_name: str,
    annotations: list[dict[str, Any]],
) -> None:
    """Write one minimal COCO split with a synthetic 800x450 source image."""
    (dataset_dir / split_name / "images").mkdir(parents=True, exist_ok=True)
    file_name = f"images/synthetic_{split_name}.jpg"
    synthetic_source().save(dataset_dir / split_name / file_name, "JPEG", quality=95)
    coco = {
        "info": {"description": "test split", "version": "1.0", "date_created": "2026-10-19"},
        "licenses": [],
        "categories": [{"id": SINGLE_CLASS_ID, "name": "hold", "supercategory": "climb"}],
        "images": [
            {
                "id": 1,
                "file_name": file_name,
                "width": SOURCE_WIDTH,
                "height": SOURCE_HEIGHT,
            }
        ],
        "annotations": annotations,
    }
    (dataset_dir / split_name / "_annotations.coco.json").write_text(
        json.dumps(coco, indent=2) + "\n", encoding="utf-8"
    )


def build_temp_dataset(root: Path) -> Path:
    """Create a three-split dataset shaped like the hold-build output."""
    dataset_dir = root / "merged"
    dataset_dir.mkdir(parents=True, exist_ok=True)
    write_split(
        dataset_dir,
        "train",
        [
            annotation(1, [80.0, 45.0, 160.0, 90.0]),  # interior box, exact transform
            annotation(2, [760.0, 420.0, 60.0, 50.0]),  # runs past the right edge, clipped
            annotation(3, [0.0, 0.0, 2.0, 2.0]),  # degenerate after 0.8 scale, dropped
        ],
    )
    write_split(dataset_dir, "val", [annotation(1, [80.0, 45.0, 160.0, 90.0])])
    write_split(dataset_dir, "test", [annotation(1, [80.0, 45.0, 160.0, 90.0])])
    sidecar = {
        "description": "pwals color sidecar, source pixels",
        "splits": {
            "train": {"1": [{"bbox": [80.0, 45.0, 160.0, 90.0], "color_family": "red"}]},
            "val": {"1": []},
            "test": {"1": []},
        },
    }
    (dataset_dir / "color_labels.json").write_text(json.dumps(sidecar) + "\n", encoding="utf-8")
    manifest = {
        "pipeline": "hold-build",
        "splits": {
            "train": {"images": 1, "annotations": 3, "annotations_sha256": "pending"},
            "val": {"images": 1, "annotations": 1, "annotations_sha256": "pending"},
            "test": {"images": 1, "annotations": 1, "annotations_sha256": "pending"},
        },
    }
    (dataset_dir / "manifest.json").write_text(json.dumps(manifest) + "\n", encoding="utf-8")
    return dataset_dir


class LetterboxGeometryTest(unittest.TestCase):
    """The bake geometry must mirror tools/eval/src/preprocess.ts exactly."""

    def test_half_up_rounding_matches_javascript(self) -> None:
        # Python round() would give 320 (banker's rounding); JavaScript gives 321.
        self.assertEqual(js_round(320.5), 321)
        self.assertEqual(js_round(321.5), 322)
        self.assertEqual(js_round(320.4), 320)
        self.assertEqual(js_round(320.6), 321)
        for value in (0.5, 1.5, 2.5, 320.5, 361.5, 639.5):
            self.assertEqual(js_round(value), harness_js_round(value))

    def test_wide_odd_height_uses_harness_pads(self) -> None:
        # 1280x641: scale 0.5, content height 320.5 -> 321, pad_y floor(319/2) = 159.
        scale, pad_x, pad_y = letterbox_geometry(1280, 641)
        harness_scale, harness_pad_x, harness_pad_y = harness_geometry(1280, 641, DEFAULT_IMAGE_SIZE)
        self.assertEqual((scale, pad_x, pad_y), (harness_scale, harness_pad_x, harness_pad_y))
        self.assertEqual(pad_y, 159)
        self.assertEqual(harness_content_size(1280, 641, DEFAULT_IMAGE_SIZE), (640, 321))

    def test_known_geometry_cases(self) -> None:
        self.assertEqual(letterbox_geometry(SOURCE_WIDTH, SOURCE_HEIGHT), (0.8, 0, 140))
        self.assertEqual(letterbox_geometry(640, 640), (1.0, 0, 0))
        self.assertEqual(letterbox_geometry(1280, 640), (0.5, 0, 160))
        for width, height in ((800, 450), (1280, 641), (641, 641), (450, 800), (1024, 1024)):
            self.assertEqual(
                letterbox_geometry(width, height),
                harness_geometry(width, height, DEFAULT_IMAGE_SIZE),
            )

    def test_letterbox_image_pads_with_pad_value(self) -> None:
        canvas, scale, pad_x, pad_y = letterbox_image(
            synthetic_source(), DEFAULT_IMAGE_SIZE, DEFAULT_PAD_VALUE
        )
        self.assertEqual(canvas.size, (DEFAULT_IMAGE_SIZE, DEFAULT_IMAGE_SIZE))
        self.assertEqual((scale, pad_x, pad_y), (EXPECTED_SCALE, EXPECTED_PAD_X, EXPECTED_PAD_Y))
        array = np.asarray(canvas)
        self.assertTrue((array[0, :, :] == DEFAULT_PAD_VALUE).all())
        self.assertTrue((array[0:pad_y, :, :] == DEFAULT_PAD_VALUE).all())
        self.assertTrue((array[pad_y + 360 :, :, :] == DEFAULT_PAD_VALUE).all())
        self.assertFalse((array[pad_y + 10, :, :] == DEFAULT_PAD_VALUE).all())


class BakeDatasetTest(unittest.TestCase):
    """End-to-end bake on a synthetic three-split dataset."""

    def setUp(self) -> None:
        self._tmp = Path(tempfile.mkdtemp(prefix="cybersend-bake-"))
        self.dataset_dir = build_temp_dataset(self._tmp)

    def tearDown(self) -> None:
        shutil.rmtree(self._tmp, ignore_errors=True)

    def _read(self, split_name: str) -> dict[str, Any]:
        path = self.dataset_dir / split_name / "_annotations.coco.json"
        return json.loads(path.read_text(encoding="utf-8"))

    def test_bake_transforms_boxes_and_counts_degradations(self) -> None:
        bake(dataset_dir=self.dataset_dir)
        coco = self._read("train")
        self.assertEqual(len(coco["annotations"]), 2)

        interior, clipped = coco["annotations"]
        self.assertEqual(interior["bbox"], [64.0, 176.0, 128.0, 72.0])
        self.assertEqual(interior["area"], round(128.0 * 72.0, 2))
        # x runs to 656 in the canvas, clipped back to 640: width 32, height 40.
        # y is 420 * 0.8 + 140 = 476.
        self.assertEqual(clipped["bbox"], [608.0, 476.0, 32.0, 40.0])

        image = coco["images"][0]
        self.assertEqual(image["width"], DEFAULT_IMAGE_SIZE)
        self.assertEqual(image["height"], DEFAULT_IMAGE_SIZE)
        self.assertEqual(image["source_width"], SOURCE_WIDTH)
        self.assertEqual(image["source_height"], SOURCE_HEIGHT)
        self.assertEqual(image["letterbox_scale"], EXPECTED_SCALE)
        self.assertEqual(image["letterbox_pad_x"], EXPECTED_PAD_X)
        self.assertEqual(image["letterbox_pad_y"], EXPECTED_PAD_Y)

        manifest = json.loads((self.dataset_dir / "manifest.json").read_text(encoding="utf-8"))
        stats = manifest["bake"]["splits"]["train"]
        self.assertEqual(stats["images_baked"], 1)
        self.assertEqual(stats["annotations_before"], 3)
        self.assertEqual(stats["annotations_after"], 2)
        self.assertEqual(stats["annotations_clipped_to_canvas"], 1)
        self.assertEqual(stats["annotations_dropped_degenerate_bbox"], 1)
        self.assertEqual(
            manifest["splits"]["train"]["annotations_sha256"], stats["annotations_sha256"]
        )
        self.assertEqual(manifest["splits"]["train"]["annotations"], 2)

        # Category id 1 is preserved end to end; no id 0 anywhere.
        category_ids = {int(entry["id"]) for entry in coco["categories"]}
        self.assertEqual(category_ids, {SINGLE_CLASS_ID})
        self.assertTrue(
            all(int(entry["category_id"]) == SINGLE_CLASS_ID for entry in coco["annotations"])
        )

    def test_baked_image_round_trips_through_harness_letterbox(self) -> None:
        bake(dataset_dir=self.dataset_dir)
        image_path = self.dataset_dir / "train" / "images" / "synthetic_train.jpg"
        with Image.open(image_path) as opened:
            self.assertEqual(opened.size, (DEFAULT_IMAGE_SIZE, DEFAULT_IMAGE_SIZE))
            rgb = np.asarray(opened.convert("RGB"))
        rgba = np.concatenate([rgb, np.full(rgb.shape[:2] + (1,), 255, np.uint8)], axis=-1)

        # Round trip: the harness letterbox on a baked image is an exact identity.
        letterboxed = harness_letterbox_rgba(rgba)
        np.testing.assert_array_equal(letterboxed, rgb, err_msg="baked image is not identity")

        # Geometry parity: harness meta on the SOURCE equals the bake meta.
        source_rgba = np.asarray(synthetic_source().convert("RGBA"))
        harness_on_source = harness_letterbox_rgba(source_rgba)
        self.assertEqual(harness_on_source.shape, (DEFAULT_IMAGE_SIZE, DEFAULT_IMAGE_SIZE, 3))
        self.assertEqual(
            harness_geometry(SOURCE_WIDTH, SOURCE_HEIGHT, DEFAULT_IMAGE_SIZE),
            (EXPECTED_SCALE, EXPECTED_PAD_X, EXPECTED_PAD_Y),
        )

        # Pad rows are exactly the pad value, content rows are not all pad.
        self.assertTrue((rgb[0, :, :] == DEFAULT_PAD_VALUE).all())
        self.assertTrue((rgb[DEFAULT_IMAGE_SIZE - 1, :, :] == DEFAULT_PAD_VALUE).all())
        self.assertFalse((rgb[EXPECTED_PAD_Y + 10, :, :] == DEFAULT_PAD_VALUE).all())

    def test_sample_box_matches_hand_computed_transform(self) -> None:
        scale, pad_x, pad_y = letterbox_geometry(SOURCE_WIDTH, SOURCE_HEIGHT)
        counters: Counter[str] = Counter()
        mapped = map_box_to_letterbox(
            [80.0, 45.0, 160.0, 90.0],
            (scale, pad_x, pad_y),
            DEFAULT_IMAGE_SIZE,
            counters,
        )
        self.assertEqual(mapped, [64.0, 176.0, 128.0, 72.0])
        self.assertEqual(dict(counters), {})

        dropped = map_box_to_letterbox(
            [0.0, 0.0, 2.0, 2.0], (scale, pad_x, pad_y), DEFAULT_IMAGE_SIZE, counters
        )
        self.assertIsNone(dropped)
        self.assertEqual(counters["annotations_dropped_degenerate_bbox"], 1)

    def test_bake_is_idempotent(self) -> None:
        bake(dataset_dir=self.dataset_dir)
        image_path = self.dataset_dir / "train" / "images" / "synthetic_train.jpg"
        annotations_path = self.dataset_dir / "train" / "_annotations.coco.json"
        image_digest = sha256_file(image_path)
        annotations_digest = sha256_file(annotations_path)
        first_manifest = json.loads(
            (self.dataset_dir / "manifest.json").read_text(encoding="utf-8")
        )
        first_bake_section = first_manifest["bake"]

        bake(dataset_dir=self.dataset_dir)
        self.assertEqual(sha256_file(image_path), image_digest)
        self.assertEqual(sha256_file(annotations_path), annotations_digest)
        # The original transform record survives the second bake unchanged.
        coco = json.loads(annotations_path.read_text(encoding="utf-8"))
        image = coco["images"][0]
        self.assertEqual(image["letterbox_scale"], EXPECTED_SCALE)
        self.assertEqual(image["letterbox_pad_x"], EXPECTED_PAD_X)
        self.assertEqual(image["letterbox_pad_y"], EXPECTED_PAD_Y)
        self.assertEqual(image["source_width"], SOURCE_WIDTH)
        self.assertEqual(image["source_height"], SOURCE_HEIGHT)
        manifest = json.loads((self.dataset_dir / "manifest.json").read_text(encoding="utf-8"))
        # A no-op second pass is a refresh: the original bake record (including
        # the dropped-box counts of the pass that transformed the data) survives,
        # and only the refresh timestamp is added.
        self.assertEqual(manifest["bake"]["splits"]["train"]["images_baked"], 1)
        self.assertEqual(manifest["bake"]["splits"]["train"]["annotations_before"], 3)
        self.assertEqual(manifest["bake"]["splits"]["train"]["annotations_after"], 2)
        self.assertEqual(
            manifest["bake"]["splits"]["train"]["annotations_dropped_degenerate_bbox"], 1
        )
        self.assertIn("refreshed_at", manifest["bake"])
        self.assertNotIn("refreshed_at", first_bake_section)
        self.assertEqual(manifest["bake"]["splits"]["train"]["annotations_sha256"], annotations_digest)

    def test_color_sidecar_boxes_follow_the_image(self) -> None:
        bake(dataset_dir=self.dataset_dir)
        sidecar = json.loads((self.dataset_dir / "color_labels.json").read_text(encoding="utf-8"))
        entry = sidecar["splits"]["train"]["1"][0]
        self.assertEqual(entry["bbox"], [64.0, 176.0, 128.0, 72.0])
        self.assertIn("letterboxed", sidecar["bboxes_frame"])

    def test_verify_passes_after_bake_and_fails_before(self) -> None:
        with self.assertRaises(SystemExit):
            verify(self.dataset_dir)
        bake(dataset_dir=self.dataset_dir)
        verify(self.dataset_dir)

    def test_verify_detects_a_category_id_regression(self) -> None:
        bake(dataset_dir=self.dataset_dir)
        annotations_path = self.dataset_dir / "val" / "_annotations.coco.json"
        coco = json.loads(annotations_path.read_text(encoding="utf-8"))
        coco["annotations"][0]["category_id"] = 0
        annotations_path.write_text(json.dumps(coco) + "\n", encoding="utf-8")
        with self.assertRaises(SystemExit):
            verify(self.dataset_dir)

    def test_bake_refuses_category_id_zero_dataset(self) -> None:
        coco_path = self.dataset_dir / "train" / "_annotations.coco.json"
        coco = json.loads(coco_path.read_text(encoding="utf-8"))
        coco["categories"] = [{"id": 0, "name": "hold", "supercategory": "climb"}]
        coco_path.write_text(json.dumps(coco) + "\n", encoding="utf-8")
        with self.assertRaises(SystemExit):
            bake(dataset_dir=self.dataset_dir)


if __name__ == "__main__":
    unittest.main()
