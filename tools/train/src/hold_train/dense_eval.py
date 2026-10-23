"""Build a harness-ready dense eval split from labelme annotations.

The merged public datasets cannot support the Phase 4 false positive and count
error criteria: their labels omit holds, so correct detections count as false
positives (docs/research.md, 2026-10-22). The dense own-gym set required by US-5
labels every hold on the wall with a tight box.

This tool turns a flat folder of photos plus labelme JSONs into the layout the
eval harness consumes:

    <dir>/photo.jpg                  JPEG only; the harness decodes with jpeg-js
    <dir>/photo.json                 labelme, polygon or rectangle shapes
    <dir>/_annotations.coco.json     written by this tool

It validates instead of assuming: every JSON needs a matching JPEG, the labelme
image size must match the JPEG, boxes must sit inside the frame, and degenerate
or duplicate boxes are reported rather than silently dropped. It also prints the
statistics that say whether the set is actually dense: holds per image, images
with no labels, and the box area distribution. A large share of very large boxes
means coarse labelling, which breaks the false positive metric the same way the
public data does.

The harness treats a split directory named "test" as the frozen test split and
refuses to score it without the acceptance flag, so name this directory for the
gym or session, never "test".

Commands:

    hold-dense-eval build --dir datasets/own_gym/dense/2026-10-22
    hold-dense-eval check --dir datasets/own_gym/dense/2026-10-22
    hold-dense-eval disagree --a datasets/own_gym/dense/a --b datasets/own_gym/dense/b
"""

from __future__ import annotations

import argparse
import statistics
from pathlib import Path
from typing import Any

from .common import DATASETS_DIR, SINGLE_CLASS_NAME, read_json, write_json
from .labelme_to_coco import _shape_to_bbox

ANNOTATION_FILE = "_annotations.coco.json"
JPEG_EXTENSIONS = (".jpg", ".jpeg")
LARGE_BOX_AREA = 10000.0
IOU_MATCH = 0.5


def _iou(a: list[float], b: list[float]) -> float:
    """IoU of two xywh boxes."""
    ax1, ay1, aw, ah = a
    bx1, by1, bw, bh = b
    ix1, iy1 = max(ax1, bx1), max(ay1, by1)
    ix2, iy2 = min(ax1 + aw, bx1 + bw), min(ay1 + ah, by1 + bh)
    inter = max(0.0, ix2 - ix1) * max(0.0, iy2 - iy1)
    if inter <= 0:
        return 0.0
    union = aw * ah + bw * bh - inter
    return inter / union if union > 0 else 0.0


def _find_image(directory: Path, labelme: dict[str, Any], annotation_path: Path) -> Path | None:
    """Locate the JPEG for a labelme file, by imagePath then by stem."""
    raw = labelme.get("imagePath")
    if raw:
        candidate = directory / Path(raw).name
        if candidate.exists():
            return candidate
    for extension in JPEG_EXTENSIONS:
        candidate = directory / (annotation_path.stem + extension)
        if candidate.exists():
            return candidate
    return None


def _image_size(path: Path) -> tuple[int, int]:
    """Read the JPEG dimensions without decoding the pixels."""
    from PIL import Image

    with Image.open(path) as image:
        return image.size


def scan(directory: Path) -> dict[str, Any]:
    """Validate every labelme file in the directory and collect the boxes."""
    errors: list[str] = []
    warnings: list[str] = []
    images: list[dict[str, Any]] = []
    annotations: list[dict[str, Any]] = []
    counts: list[int] = []
    areas: list[float] = []
    duplicate_boxes = 0
    degenerate_boxes = 0

    labelme_paths = sorted(
        path for path in directory.glob("*.json") if path.name != ANNOTATION_FILE
    )
    if not labelme_paths:
        raise SystemExit(f"no labelme .json files under {directory}")

    for image_id, annotation_path in enumerate(labelme_paths, start=1):
        labelme = read_json(annotation_path)
        image_path = _find_image(directory, labelme, annotation_path)
        if image_path is None:
            errors.append(f"{annotation_path.name}: no matching JPEG in the folder")
            continue
        if image_path.suffix.lower() not in JPEG_EXTENSIONS:
            errors.append(f"{image_path.name}: the harness decodes JPEG only, found {image_path.suffix}")
            continue

        actual_width, actual_height = _image_size(image_path)
        declared = (int(labelme.get("imageWidth", 0)), int(labelme.get("imageHeight", 0)))
        if declared != (actual_width, actual_height):
            errors.append(
                f"{annotation_path.name}: labelme says {declared[0]}x{declared[1]} but the JPEG is "
                f"{actual_width}x{actual_height}; relabel or fix the JSON"
            )
            continue

        boxes: list[list[float]] = []
        for shape in labelme.get("shapes", []):
            converted = _shape_to_bbox(shape, actual_width, actual_height)
            if converted is None:
                degenerate_boxes += 1
                continue
            bbox = converted[0]
            boxes.append(bbox)

        seen: list[list[float]] = []
        for bbox in boxes:
            if any(_iou(bbox, other) > 0.9 for other in seen):
                duplicate_boxes += 1
            seen.append(bbox)
            annotations.append(
                {
                    "id": len(annotations) + 1,
                    "image_id": image_id,
                    "category_id": 1,
                    "bbox": bbox,
                    "area": round(bbox[2] * bbox[3], 2),
                    "iscrowd": 0,
                }
            )
            areas.append(bbox[2] * bbox[3])

        if not boxes:
            warnings.append(f"{image_path.name}: no hold boxes, the model scores it as pure background")
        counts.append(len(boxes))
        images.append(
            {
                "id": image_id,
                "file_name": image_path.name,
                "width": actual_width,
                "height": actual_height,
            }
        )

    coco = {
        "info": {
            "description": (
                "CyberSend dense own-gym hold eval set, single class, tight boxes, "
                "built by hold-dense-eval"
            ),
            "version": "1.0",
        },
        "licenses": [],
        "categories": [{"id": 1, "name": SINGLE_CLASS_NAME, "supercategory": "climb"}],
        "images": images,
        "annotations": annotations,
    }

    areas.sort()
    percentile = lambda p: areas[min(len(areas) - 1, int(len(areas) * p))] if areas else 0.0
    stats = {
        "images": len(images),
        "instances": len(annotations),
        "holds_per_image_median": statistics.median(counts) if counts else 0,
        "holds_per_image_min": min(counts) if counts else 0,
        "holds_per_image_max": max(counts) if counts else 0,
        "images_without_labels": sum(1 for count in counts if count == 0),
        "degenerate_boxes_dropped": degenerate_boxes,
        "duplicate_boxes_flagged": duplicate_boxes,
        "box_area_px2_median": round(percentile(0.5), 1),
        "box_area_px2_p90": round(percentile(0.9), 1),
        "share_boxes_over_10000_px2": round(
            sum(1 for area in areas if area > LARGE_BOX_AREA) / max(1, len(areas)), 4
        ),
    }
    return {"coco": coco, "stats": stats, "errors": errors, "warnings": warnings}


def _print_stats(stats: dict[str, Any], errors: list[str], warnings: list[str]) -> None:
    print("--- dense set statistics ---")
    for key, value in stats.items():
        print(f"  {key:34s} {value}")
    if warnings:
        print(f"--- warnings ({len(warnings)}) ---")
        for warning in warnings[:20]:
            print(f"  {warning}")
    if errors:
        print(f"--- errors ({len(errors)}) ---")
        for error in errors[:20]:
            print(f"  {error}")


def build(directory: Path, dry_run: bool = False) -> int:
    """Validate the folder and write the COCO file the harness reads."""
    result = scan(directory)
    _print_stats(result["stats"], result["errors"], result["warnings"])
    if result["errors"]:
        print(f"not written: {len(result['errors'])} errors must be fixed first")
        return 1
    if dry_run:
        print("check only: no file written")
        return 0
    output = directory / ANNOTATION_FILE
    write_json(output, result["coco"])
    print(f"wrote {output}")
    try:
        split_arg = f"../train/{directory.resolve().relative_to(DATASETS_DIR.parent)}"
    except ValueError:
        split_arg = str(directory.resolve())
    print(
        "next: score it with the harness, for example "
        "cd tools/eval && npm run eval -- --model ../train/artifacts/holds_detector_d1.onnx "
        f"--split-dir {split_arg} --confidence <chosen on val>"
    )
    return 0


def _boxes_by_image(directory: Path) -> dict[str, list[list[float]]]:
    """Boxes per image name, from a labelme folder (no COCO needed)."""
    boxes: dict[str, list[list[float]]] = {}
    for annotation_path in sorted(
        path for path in directory.glob("*.json") if path.name != ANNOTATION_FILE
    ):
        labelme = read_json(annotation_path)
        image_path = _find_image(directory, labelme, annotation_path)
        if image_path is None:
            continue
        width = int(labelme.get("imageWidth", 0))
        height = int(labelme.get("imageHeight", 0))
        converted: list[list[float]] = []
        for shape in labelme.get("shapes", []):
            box = _shape_to_bbox(shape, width, height)
            if box is not None:
                converted.append(box[0])
        boxes[image_path.name] = converted
    return boxes


def disagree(first: Path, second: Path) -> int:
    """Report hold presence disagreement between two annotation sets."""
    a = _boxes_by_image(first)
    b = _boxes_by_image(second)
    common = sorted(set(a) & set(b))
    if not common:
        print("no images in common; annotators must use the same file names")
        return 1
    total_matched = 0
    total_only_a = 0
    total_only_b = 0
    rows: list[tuple[str, int, int, int]] = []
    for name in common:
        boxes_a = a[name]
        boxes_b = b[name]
        claimed = [False] * len(boxes_b)
        matched = 0
        for box in boxes_a:
            best = -1
            best_iou = IOU_MATCH
            for index, other in enumerate(boxes_b):
                if claimed[index]:
                    continue
                overlap = _iou(box, other)
                if overlap >= best_iou:
                    best_iou = overlap
                    best = index
            if best >= 0:
                claimed[best] = True
                matched += 1
        only_a = len(boxes_a) - matched
        only_b = len(boxes_b) - matched
        total_matched += matched
        total_only_a += only_a
        total_only_b += only_b
        if only_a or only_b:
            rows.append((name, matched, only_a, only_b))

    union = total_matched + total_only_a + total_only_b
    rate = (total_only_a + total_only_b) / max(1, union)
    print(f"--- double annotation report ({len(common)} images) ---")
    print(f"  matched at IoU {IOU_MATCH}: {total_matched}")
    print(f"  only in {first.name}: {total_only_a}")
    print(f"  only in {second.name}: {total_only_b}")
    print(f"  presence disagreement: {rate:.2%} (US-5 target: <= 5%)")
    for name, matched, only_a, only_b in rows[:20]:
        print(f"  {name}: matched={matched} only_a={only_a} only_b={only_b}")
    return 0 if rate <= 0.05 else 1


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    build_parser = subparsers.add_parser("build", help="validate and write _annotations.coco.json")
    build_parser.add_argument("--dir", type=Path, required=True)

    check_parser = subparsers.add_parser("check", help="validate without writing")
    check_parser.add_argument("--dir", type=Path, required=True)

    disagree_parser = subparsers.add_parser("disagree", help="double annotation disagreement report")
    disagree_parser.add_argument("--a", type=Path, required=True)
    disagree_parser.add_argument("--b", type=Path, required=True)

    args = parser.parse_args()
    if args.command == "build":
        raise SystemExit(build(args.dir))
    if args.command == "check":
        raise SystemExit(build(args.dir, dry_run=True))
    raise SystemExit(disagree(args.a, args.b))


if __name__ == "__main__":
    main()
