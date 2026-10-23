"""Unit tests for the dense eval set builder (hold-dense-eval).

Run from tools/train:

    uv run python -m unittest discover -s tests -v

The builder is the gate between hand labelling and the eval harness, so the tests
pin the things that would silently corrupt a measurement: image and label size
agreement, JPEG only (the harness decodes with jpeg-js), degenerate shapes being
dropped rather than written as zero-area boxes, duplicate boxes being flagged,
and a build refusing to write when validation fails.
"""

from __future__ import annotations

import json
import shutil
import tempfile
import unittest
from pathlib import Path
from typing import Any

from PIL import Image

from hold_train.dense_eval import ANNOTATION_FILE, build, disagree, scan


def _write_image(path: Path, width: int = 64, height: int = 48) -> None:
    Image.new("RGB", (width, height), (40, 60, 80)).save(path, format="JPEG")


def _write_labelme(
    path: Path,
    image_name: str,
    width: int,
    height: int,
    boxes: list[list[list[float]]],
    image_path: str | None = None,
) -> None:
    shapes: list[dict[str, Any]] = []
    for points in boxes:
        shapes.append(
            {
                "label": "hold",
                "points": points,
                "group_id": None,
                "shape_type": "rectangle",
                "flags": {},
            }
        )
    payload = {
        "version": "5.0.1",
        "flags": {},
        "shapes": shapes,
        "imagePath": image_path or image_name,
        "imageData": None,
        "imageHeight": height,
        "imageWidth": width,
    }
    path.write_text(json.dumps(payload), encoding="utf-8")


class DenseEvalTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = Path(tempfile.mkdtemp(prefix="dense-eval-"))

    def tearDown(self) -> None:
        shutil.rmtree(self.directory, ignore_errors=True)

    def test_build_writes_harness_coco(self) -> None:
        _write_image(self.directory / "wall-a.jpg", 64, 48)
        _write_labelme(
            self.directory / "wall-a.json",
            "wall-a.jpg",
            64,
            48,
            [
                [[0, 0], [10, 10]],
                [[20, 20], [40, 35]],
            ],
        )
        _write_image(self.directory / "wall-b.jpg", 32, 32)
        _write_labelme(self.directory / "wall-b.json", "wall-b.jpg", 32, 32, [[[1, 1], [5, 6]]])

        exit_code = build(self.directory)
        self.assertEqual(exit_code, 0)

        coco = json.loads((self.directory / ANNOTATION_FILE).read_text())
        self.assertEqual(len(coco["images"]), 2)
        self.assertEqual(len(coco["annotations"]), 3)
        self.assertEqual(coco["categories"][0]["name"], "hold")
        self.assertEqual(coco["images"][0]["file_name"], "wall-a.jpg")
        self.assertEqual(coco["images"][0]["width"], 64)
        self.assertEqual(coco["annotations"][0]["bbox"], [0.0, 0.0, 10.0, 10.0])
        self.assertEqual(coco["annotations"][0]["image_id"], 1)

    def test_degenerate_shape_is_dropped_and_counted(self) -> None:
        _write_image(self.directory / "wall.jpg", 64, 48)
        _write_labelme(
            self.directory / "wall.json",
            "wall.jpg",
            64,
            48,
            [
                [[5, 5], [10, 12]],
                [[20, 20], [20, 30]],
            ],
        )
        result = scan(self.directory)
        self.assertEqual(result["stats"]["instances"], 1)
        self.assertEqual(result["stats"]["degenerate_boxes_dropped"], 1)

    def test_duplicate_boxes_are_flagged(self) -> None:
        _write_image(self.directory / "wall.jpg", 64, 48)
        _write_labelme(
            self.directory / "wall.json",
            "wall.jpg",
            64,
            48,
            [
                [[5, 5], [25, 25]],
                [[5, 5], [25, 25]],
            ],
        )
        result = scan(self.directory)
        self.assertEqual(result["stats"]["instances"], 2)
        self.assertEqual(result["stats"]["duplicate_boxes_flagged"], 1)

    def test_missing_image_is_an_error_and_blocks_the_write(self) -> None:
        _write_labelme(self.directory / "wall.json", "wall.jpg", 64, 48, [[[1, 1], [4, 4]]])
        result = scan(self.directory)
        self.assertEqual(len(result["errors"]), 1)
        exit_code = build(self.directory)
        self.assertEqual(exit_code, 1)
        self.assertFalse((self.directory / ANNOTATION_FILE).exists())

    def test_size_mismatch_is_an_error(self) -> None:
        _write_image(self.directory / "wall.jpg", 64, 48)
        _write_labelme(self.directory / "wall.json", "wall.jpg", 100, 100, [[[1, 1], [4, 4]]])
        result = scan(self.directory)
        self.assertEqual(len(result["errors"]), 1)
        self.assertIn("labelme says", result["errors"][0])

    def test_non_jpeg_is_an_error(self) -> None:
        Image.new("RGB", (16, 16), (0, 0, 0)).save(self.directory / "wall.png", format="PNG")
        _write_labelme(
            self.directory / "wall.json",
            "wall.jpg",
            16,
            16,
            [[[1, 1], [4, 4]]],
            image_path="wall.png",
        )
        result = scan(self.directory)
        self.assertEqual(len(result["errors"]), 1)
        self.assertIn("JPEG", result["errors"][0])

    def test_empty_image_is_a_warning_not_an_error(self) -> None:
        _write_image(self.directory / "wall.jpg", 32, 32)
        _write_labelme(self.directory / "wall.json", "wall.jpg", 32, 32, [])
        result = scan(self.directory)
        self.assertEqual(result["errors"], [])
        self.assertEqual(result["stats"]["images_without_labels"], 1)
        self.assertEqual(len(result["warnings"]), 1)

    def test_disagree_reports_presence_difference(self) -> None:
        first = self.directory / "a"
        second = self.directory / "b"
        first.mkdir()
        second.mkdir()
        for directory in (first, second):
            _write_image(directory / "wall.jpg", 64, 48)
        _write_labelme(
            first / "wall.json",
            "wall.jpg",
            64,
            48,
            [
                [[5, 5], [20, 20]],
                [[30, 30], [45, 45]],
            ],
        )
        _write_labelme(
            second / "wall.json",
            "wall.jpg",
            64,
            48,
            [
                [[5, 5], [20, 20]],
            ],
        )
        exit_code = disagree(first, second)
        self.assertEqual(exit_code, 1)


if __name__ == "__main__":
    unittest.main()
