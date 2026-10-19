"""Convert labelme polygon annotations into a single-class COCO file.

Source: ClimbInst-style layout, datasets/<name>/<split>/{images,annotations} where each
annotation is a labelme JSON with polygon (or rectangle) shapes. Every shape label is
unified into the single training class "hold" (ClimbInst annotates holds and volumes as
one class already; raw label counts are recorded in the output stats for transparency).

Output: datasets/<name>/coco/instances.json in COCO detection format with bbox xywh.
"""

from __future__ import annotations

import argparse
from collections import Counter
from pathlib import Path
from typing import Any

from .common import DATASETS_DIR, SINGLE_CLASS_NAME, read_json, write_json

SOURCE_SPLITS = ("train", "validation", "test")
IMAGE_EXTENSIONS = (".jpg", ".jpeg", ".png")


def _polygon_area(points: list[list[float]]) -> float:
    """Shoelace area of a polygon given as [[x, y], ...]."""
    area = 0.0
    count = len(points)
    for index in range(count):
        x1, y1 = points[index]
        x2, y2 = points[(index + 1) % count]
        area += x1 * y2 - x2 * y1
    return abs(area) / 2.0


def _shape_to_bbox(shape: dict[str, Any], width: int, height: int) -> tuple[list[float], float] | None:
    """Return (bbox_xywh, area) for a labelme shape, clamped to the image, or None."""
    shape_type = shape.get("shape_type", "polygon")
    points = shape["points"]
    if shape_type == "rectangle" and len(points) >= 2:
        (x1, y1), (x2, y2) = points[0], points[1]
        area = abs(x2 - x1) * abs(y2 - y1)
    elif shape_type == "polygon" and len(points) >= 3:
        xs = [point[0] for point in points]
        ys = [point[1] for point in points]
        x1, x2 = min(xs), max(xs)
        y1, y2 = min(ys), max(ys)
        area = _polygon_area([[float(p[0]), float(p[1])] for p in points])
    else:
        return None

    x1 = max(0.0, min(float(x1), float(width)))
    x2 = max(0.0, min(float(x2), float(width)))
    y1 = max(0.0, min(float(y1), float(height)))
    y2 = max(0.0, min(float(y2), float(height)))
    box_w = x2 - x1
    box_h = y2 - y1
    if box_w < 1.0 or box_h < 1.0:
        return None
    return [round(x1, 2), round(y1, 2), round(box_w, 2), round(box_h, 2)], max(area, 1.0)


def convert(dataset_dir: Path, source_splits: tuple[str, ...] = SOURCE_SPLITS) -> Path:
    """Convert labelme annotations under dataset_dir into coco/instances.json."""
    images: list[dict[str, Any]] = []
    annotations: list[dict[str, Any]] = []
    raw_labels: Counter[str] = Counter()
    image_id = 0
    annotation_id = 0

    for split in source_splits:
        annotation_dir = dataset_dir / split / "annotations"
        image_dir = dataset_dir / split / "images"
        if not annotation_dir.is_dir():
            print(f"  skipping missing split '{split}'")
            continue
        for annotation_path in sorted(annotation_dir.glob("*.json")):
            labelme = read_json(annotation_path)
            image_path_name = Path(labelme.get("imagePath", annotation_path.stem)).name
            image_file = image_dir / image_path_name
            if not image_file.exists():
                matches = [ext for ext in IMAGE_EXTENSIONS if (image_dir / (annotation_path.stem + ext)).exists()]
                if not matches:
                    print(f"  WARNING: no image for {annotation_path}")
                    continue
                image_file = image_dir / (annotation_path.stem + matches[0])
            width = int(labelme.get("imageWidth", 0))
            height = int(labelme.get("imageHeight", 0))
            if width <= 0 or height <= 0:
                print(f"  WARNING: {annotation_path} missing image size, skipping")
                continue

            image_id += 1
            images.append(
                {
                    "id": image_id,
                    "file_name": f"{split}/images/{image_file.name}",
                    "width": width,
                    "height": height,
                }
            )
            for shape in labelme.get("shapes", []):
                raw_labels[str(shape.get("label", "unknown"))] += 1
                converted = _shape_to_bbox(shape, width, height)
                if converted is None:
                    continue
                bbox, area = converted
                annotation_id += 1
                annotations.append(
                    {
                        "id": annotation_id,
                        "image_id": image_id,
                        "category_id": 1,
                        "bbox": bbox,
                        "area": round(area, 2),
                        "iscrowd": 0,
                    }
                )

    coco = {
        "info": {
            "description": "CyberSend hold detection, single class, converted from labelme polygons",
            "version": "1.0",
        },
        "licenses": [],
        "categories": [{"id": 1, "name": SINGLE_CLASS_NAME, "supercategory": "climb"}],
        "images": images,
        "annotations": annotations,
    }
    output_path = dataset_dir / "coco" / "instances.json"
    write_json(output_path, coco)
    stats = {
        "images": len(images),
        "instances": len(annotations),
        "raw_shape_labels": dict(raw_labels),
    }
    print(f"Converted {stats['images']} images, {stats['instances']} instances -> {output_path}")
    print(f"Raw labelme labels unified into class '{SINGLE_CLASS_NAME}': {stats['raw_shape_labels']}")
    return output_path


def main() -> None:
    """Entry point for the hold-convert console script."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-dir", type=Path, default=DATASETS_DIR / "climbinst_smoke")
    args = parser.parse_args()
    convert(args.dataset_dir)


if __name__ == "__main__":
    main()
