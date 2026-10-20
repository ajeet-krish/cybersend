"""Unit tests for hold-split letterbox parity with hold-bake and the harness.

Run from tools/train:

    uv run python -m unittest discover -s tests -v

hold-split writes already-letterboxed 640x640 frames, so its geometry must
match tools/eval/src/preprocess.ts letterboxGeometryFor exactly. The critical
regression case is 1280x641: the content height is exactly 320.5 and
JavaScript Math.round rounds halves up to 321 (padY 159), while Python's
banker's round() would say 320 (padY 160). This pins the shared half-up rule
through the split writer, mirroring the harness expectation documented in
tools/eval/src/baked_parity.test.ts ("harness geometry matches hold-bake on
the half-up rounding case").
"""

from __future__ import annotations

import json
import math
import shutil
import tempfile
import unittest
from collections import Counter
from pathlib import Path

import numpy as np
from PIL import Image

from hold_train import bake_dataset, common, split_dataset
from hold_train.bake_dataset import (
    DEFAULT_IMAGE_SIZE,
    DEFAULT_PAD_VALUE,
    js_round,
    letterbox_geometry,
    map_box_to_letterbox,
)
from hold_train.split_dataset import split_and_prepare

ODD_SOURCE_WIDTH = 1280
ODD_SOURCE_HEIGHT = 641
CONTENT_VALUE = 200


def harness_geometry(width: int, height: int, size: int) -> tuple[float, int, int]:
    """Faithful port of preprocess.ts letterboxGeometryFor: (scale, pad_x, pad_y).

    Mirrors the harness expectation asserted in
    tools/eval/src/baked_parity.test.ts:124-132 (1280x641 gives padY 159).
    """
    scale = min(size / width, size / height)
    content_width = max(1, math.floor(width * scale + 0.5))
    content_height = max(1, math.floor(height * scale + 0.5))
    return scale, math.floor((size - content_width) / 2), math.floor((size - content_height) / 2)


def solid_source(width: int, height: int) -> Image.Image:
    """Flat non-pad-color image so content rows differ from pad rows exactly."""
    return Image.fromarray(np.full((height, width, 3), CONTENT_VALUE, np.uint8), "RGB")


class SplitLetterboxWriterTest(unittest.TestCase):
    """hold-split must share hold-bake's writer and half-up rounding exactly."""

    def test_split_imports_the_bake_letterbox_writer(self) -> None:
        # One implementation, no third copy: the split reuses the bake
        # functions, so the two letterbox writers cannot drift apart again.
        self.assertIs(split_dataset.letterbox_image, bake_dataset.letterbox_image)
        self.assertIs(split_dataset.map_box_to_letterbox, bake_dataset.map_box_to_letterbox)
        self.assertIs(js_round, common.js_round)
        self.assertIs(bake_dataset.js_round, common.js_round)

    def test_half_up_content_and_pad_on_1280x641(self) -> None:
        canvas, scale, pad_x, pad_y = split_dataset.letterbox_image(
            solid_source(ODD_SOURCE_WIDTH, ODD_SOURCE_HEIGHT),
            DEFAULT_IMAGE_SIZE,
            DEFAULT_PAD_VALUE,
        )
        self.assertEqual(scale, 0.5)
        self.assertEqual((pad_x, pad_y), (0, 159))

        # Content occupies rows 159..479 inclusive: exactly 321 rows (320.5
        # rounded up), with 159 pad rows above and 160 below. Banker's rounding
        # would have written 320 content rows starting at padY 160.
        array = np.asarray(canvas)
        self.assertTrue((array[158, :, :] == DEFAULT_PAD_VALUE).all())
        self.assertTrue((array[159, :, :] == CONTENT_VALUE).all())
        self.assertTrue((array[479, :, :] == CONTENT_VALUE).all())
        self.assertTrue((array[480, :, :] == DEFAULT_PAD_VALUE).all())

        # Cross-check against the harness expectation from baked_parity.test.ts.
        self.assertEqual(
            harness_geometry(ODD_SOURCE_WIDTH, ODD_SOURCE_HEIGHT, DEFAULT_IMAGE_SIZE),
            (0.5, 0, 159),
        )
        self.assertEqual(max(1, math.floor(ODD_SOURCE_HEIGHT * 0.5 + 0.5)), 321)
        # hold-bake geometry agrees with the split writer (same code path).
        self.assertEqual(letterbox_geometry(ODD_SOURCE_WIDTH, ODD_SOURCE_HEIGHT), (0.5, 0, 159))
        self.assertEqual(js_round(320.5), 321)
        self.assertEqual(js_round(321.5), 322)

    def test_box_transform_threshold_and_canvas_bounds(self) -> None:
        meta = letterbox_geometry(ODD_SOURCE_WIDTH, ODD_SOURCE_HEIGHT)  # (0.5, 0, 159)
        counters: Counter[str] = Counter()

        # 3.98 px source scales to 1.99 px: dropped under the shared 2 px
        # threshold (hold-split used to keep anything at or above 1 px).
        dropped = map_box_to_letterbox(
            [100.0, 100.0, 3.98, 3.98], meta, DEFAULT_IMAGE_SIZE, counters
        )
        self.assertIsNone(dropped)
        self.assertEqual(counters["annotations_dropped_degenerate_bbox"], 1)

        # 4 px source scales to exactly 2 px: kept.
        kept = map_box_to_letterbox([100.0, 100.0, 4.0, 4.0], meta, DEFAULT_IMAGE_SIZE, counters)
        self.assertEqual(kept, [50.0, 209.0, 2.0, 2.0])

        # Canvas bounds: no emitted box may cross the 640 edge, even after
        # rounding to 2 decimals (the overshoot fix in the shared transform).
        for x in (0.0, 0.01, 499.99, 1270.0, 1279.5):
            for width in (0.5, 4.0, 39.99, 60.0, 200.0):
                mapped = map_box_to_letterbox(
                    [x, 100.0, width, 40.0], meta, DEFAULT_IMAGE_SIZE, counters
                )
                if mapped is None:
                    continue
                self.assertLessEqual(mapped[0] + mapped[2], DEFAULT_IMAGE_SIZE + 1e-9)
        for y in (0.0, 0.01, 300.0, 479.5):
            for height in (0.5, 4.0, 39.99, 200.0):
                mapped = map_box_to_letterbox(
                    [100.0, y, 40.0, height], meta, DEFAULT_IMAGE_SIZE, counters
                )
                if mapped is None:
                    continue
                self.assertLessEqual(mapped[1] + mapped[3], DEFAULT_IMAGE_SIZE + 1e-9)


class SplitAndPrepareTest(unittest.TestCase):
    """End-to-end split writes half-up geometry into the RF-DETR layout."""

    def setUp(self) -> None:
        self._tmp = Path(tempfile.mkdtemp(prefix="cybersend-split-"))
        self.dataset_dir = self._tmp / "own_gym"
        (self.dataset_dir / "images").mkdir(parents=True)
        solid_source(ODD_SOURCE_WIDTH, ODD_SOURCE_HEIGHT).save(
            self.dataset_dir / "images" / "gym_photo.jpg", "JPEG", quality=95
        )
        coco = {
            "info": {"description": "test split", "version": "1.0"},
            "licenses": [],
            "categories": [{"id": 1, "name": "hold", "supercategory": "climb"}],
            "images": [
                {
                    "id": 1,
                    "file_name": "images/gym_photo.jpg",
                    "width": ODD_SOURCE_WIDTH,
                    "height": ODD_SOURCE_HEIGHT,
                }
            ],
            "annotations": [
                {
                    "id": 1,
                    "image_id": 1,
                    "category_id": 1,
                    "bbox": [200.0, 100.0, 160.0, 80.0],
                    "area": 12800.0,
                    "iscrowd": 0,
                },
                {
                    "id": 2,
                    "image_id": 1,
                    "category_id": 1,
                    "bbox": [100.0, 100.0, 3.98, 3.98],
                    "area": 15.84,
                    "iscrowd": 0,
                },
            ],
        }
        self.coco_path = self.dataset_dir / "coco" / "instances.json"
        self.coco_path.parent.mkdir(parents=True)
        self.coco_path.write_text(json.dumps(coco) + "\n", encoding="utf-8")
        self.output_dir = self.dataset_dir / "prepared"

    def tearDown(self) -> None:
        shutil.rmtree(self._tmp, ignore_errors=True)

    def test_split_and_prepare_records_half_up_geometry(self) -> None:
        split_and_prepare(
            coco_path=self.coco_path,
            dataset_dir=self.dataset_dir,
            output_dir=self.output_dir,
            seed=1,
            train_ratio=1.0,
            val_ratio=0.0,
            test_ratio=0.0,
            image_size=DEFAULT_IMAGE_SIZE,
            pad_value=DEFAULT_PAD_VALUE,
        )
        written = json.loads(
            (self.output_dir / "train" / "_annotations.coco.json").read_text(encoding="utf-8")
        )
        image = written["images"][0]
        self.assertEqual(image["letterbox_scale"], 0.5)
        self.assertEqual(image["letterbox_pad_x"], 0)
        # Content height 320.5 rounds up to 321, so padY is 159, not 160.
        self.assertEqual(image["letterbox_pad_y"], 159)
        self.assertEqual((image["width"], image["height"]), (DEFAULT_IMAGE_SIZE, DEFAULT_IMAGE_SIZE))

        # The 3.98 px box scales to 1.99 px and is dropped by the 2 px rule;
        # the surviving box maps through scale and pad unchanged.
        self.assertEqual(len(written["annotations"]), 1)
        self.assertEqual(written["annotations"][0]["bbox"], [100.0, 209.0, 80.0, 40.0])

        manifest = json.loads(
            (self.dataset_dir / "split_manifest.json").read_text(encoding="utf-8")
        )
        train = manifest["splits"]["train"]
        self.assertEqual(train["annotations_dropped_degenerate_bbox"], 1)
        self.assertEqual(train["annotations_clipped_to_canvas"], 0)
        self.assertIn("halves up", manifest["letterbox"]["content_rounding"])


if __name__ == "__main__":
    unittest.main()
