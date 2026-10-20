"""Bake the shared letterbox-640 inference preprocess into the merged dataset.

hold-build writes source-resolution images with boxes in source pixels. This
step (hold-bake) rewrites datasets/merged in place so that the inference
preprocess is part of the data:

    images     letterboxed to 640x640 RGB JPEG (pad value 114, aspect ratio
               preserved, padding centered)
    boxes      scaled by the letterbox scale, offset by the pad, clipped to the
               640 canvas; boxes under 2 px on a side after the transform are
               dropped and counted
    color sidecar (color_labels.json) boxes transformed with their image so the
               sidecar keeps matching the split annotation files

Padding placement and rounding are byte-consistent with the shared harness
preprocess in tools/eval/src/preprocess.ts (letterboxGeometryFor):

    scale   = min(640 / width, 640 / height)
    content = max(1, Math.round(size * scale))   (JavaScript rounds halves UP, so
                                                  js_round from hold_train.common
                                                  is used instead of Python's
                                                  banker's rounding)
    pad     = Math.floor((640 - content) / 2)    (centered)

Once the images are 640x640 the harness letterbox becomes an exact identity
(scale 1, zero pads, no resampling), so the app, the eval harness, and
RF-DETR's own Resize((640, 640)) eval transform all see the training pixels.
Detections and boxes therefore live in one frame end to end.

Baking is deterministic and idempotent: images already at 640x640 are skipped
(no second JPEG generation), and their boxes pass through unchanged, so a
second bake rewrites no bytes and keeps the original bake record in the
manifest. Rebuild with `uv run hold-build --force` (then `uv run hold-bake`)
reproduces the same layout; note that a rebuild, and any bake that actually
transforms boxes, changes the _annotations.coco.json SHA256 digests recorded in
manifest.json, because the category ids, image records, and box coordinates are
part of those files. Split membership (including the frozen test split) is
never touched.

Run `uv run hold-bake --verify` to re-check a baked dataset without writing.
"""

from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from PIL import Image

from .common import (
    DATASETS_DIR,
    SINGLE_CLASS_ID,
    js_round,
    read_json,
    sha256_file,
    write_json,
)

DEFAULT_DATASET_DIR = DATASETS_DIR / "merged"
SPLIT_NAMES = ("train", "val", "test")
DEFAULT_IMAGE_SIZE = 640
DEFAULT_PAD_VALUE = 114
DEFAULT_JPEG_QUALITY = 92
MIN_BOX_SIDE_PX = 2.0
# (scale, pad_x, pad_y) for one image, the full geometry of the transform.
BakeMeta = tuple[float, int, int]


def letterbox_geometry(width: int, height: int, size: int = DEFAULT_IMAGE_SIZE) -> BakeMeta:
    """Return (scale, pad_x, pad_y) matching preprocess.ts letterboxGeometryFor."""
    if width <= 0 or height <= 0:
        raise ValueError(f"invalid source size {width}x{height}")
    scale = min(size / width, size / height)
    content_width = max(1, js_round(width * scale))
    content_height = max(1, js_round(height * scale))
    pad_x = (size - content_width) // 2
    pad_y = (size - content_height) // 2
    return scale, pad_x, pad_y


def letterbox_image(
    image: Image.Image, size: int, pad_value: int
) -> tuple[Image.Image, float, int, int]:
    """Letterbox into size x size: aspect preserved, centered padding, BICUBIC.

    Returns (canvas, scale, pad_x, pad_y). This is the single letterbox writer
    for the whole pipeline: hold-bake calls it directly and hold-split imports
    it, so the two cannot drift. BICUBIC matches the resampling convention
    recorded by hold-split and the ONNX export manifest.
    """
    width, height = image.size
    scale, pad_x, pad_y = letterbox_geometry(width, height, size)
    content_width = max(1, js_round(width * scale))
    content_height = max(1, js_round(height * scale))
    resized = image.convert("RGB").resize((content_width, content_height), Image.BICUBIC)
    canvas = Image.new("RGB", (size, size), (pad_value, pad_value, pad_value))
    canvas.paste(resized, (pad_x, pad_y))
    return canvas, scale, pad_x, pad_y


def map_box_to_letterbox(
    bbox: list[float],
    meta: BakeMeta,
    size: int,
    counters: Counter[str],
) -> list[float] | None:
    """Map one xywh box from source pixels into the letterboxed canvas.

    Scales and pads with the image, clips to the canvas, rounds to 2 decimals
    like hold-build, and drops degenerate boxes (counted, never emitted).
    hold-split imports this function too, so both letterbox writers share one
    box transform and one degenerate threshold (MIN_BOX_SIDE_PX).
    """
    scale, pad_x, pad_y = meta
    x, y, box_width, box_height = bbox
    new_x = x * scale + pad_x
    new_y = y * scale + pad_y
    new_w = box_width * scale
    new_h = box_height * scale
    x1 = max(0.0, min(new_x, float(size)))
    y1 = max(0.0, min(new_y, float(size)))
    x2 = max(0.0, min(new_x + new_w, float(size)))
    y2 = max(0.0, min(new_y + new_h, float(size)))
    clipped_w = x2 - x1
    clipped_h = y2 - y1
    if abs(clipped_w - new_w) > 1e-6 or abs(clipped_h - new_h) > 1e-6:
        counters["annotations_clipped_to_canvas"] += 1
    if clipped_w < MIN_BOX_SIDE_PX or clipped_h < MIN_BOX_SIDE_PX:
        counters["annotations_dropped_degenerate_bbox"] += 1
        return None
    rounded_x = round(x1, 2)
    rounded_y = round(y1, 2)
    rounded_w = round(clipped_w, 2)
    rounded_h = round(clipped_h, 2)
    # Rounding to 2 decimals can push a box a hundredth past the canvas edge.
    if rounded_x + rounded_w > size:
        rounded_w = round(size - rounded_x, 2)
    if rounded_y + rounded_h > size:
        rounded_h = round(size - rounded_y, 2)
    if rounded_w < MIN_BOX_SIDE_PX or rounded_h < MIN_BOX_SIDE_PX:
        counters["annotations_dropped_degenerate_bbox"] += 1
        return None
    return [rounded_x, rounded_y, rounded_w, rounded_h]


def _load_split(dataset_dir: Path, split_name: str) -> tuple[Path, dict[str, Any]]:
    """Read one split's COCO file, failing loudly when it is missing."""
    coco_path = dataset_dir / split_name / "_annotations.coco.json"
    if not coco_path.exists():
        raise SystemExit(f"split annotation file not found: {coco_path}")
    coco = read_json(coco_path)
    category_ids = {int(category["id"]) for category in coco.get("categories", [])}
    if category_ids != {SINGLE_CLASS_ID}:
        raise SystemExit(
            f"{split_name} declares category ids {sorted(category_ids)}, expected "
            f"{{{SINGLE_CLASS_ID}}}; run 'uv run hold-build --force' first "
            "(hold-bake never remaps category ids)"
        )
    return coco_path, coco


def _bake_split(
    dataset_dir: Path,
    split_name: str,
    size: int,
    pad_value: int,
    jpeg_quality: int,
) -> tuple[dict[str, Any], dict[int, BakeMeta]]:
    """Letterbox one split in place and rewrite its COCO file; return stats + metas."""
    split_dir = dataset_dir / split_name
    coco_path, coco = _load_split(dataset_dir, split_name)
    counters: Counter[str] = Counter()
    meta_by_image_id: dict[int, BakeMeta] = {}
    baked_images: list[dict[str, Any]] = []

    for image in coco["images"]:
        declared = (int(image["width"]), int(image["height"]))
        image_path = split_dir / image["file_name"]
        if not image_path.exists():
            raise SystemExit(f"referenced image missing on disk: {image_path}")
        with Image.open(image_path) as opened:
            actual = opened.size
            if actual != declared:
                raise SystemExit(
                    f"{image_path} is {actual[0]}x{actual[1]} but the annotation file "
                    f"says {declared[0]}x{declared[1]}; rebuild with hold-build --force"
                )
            if actual == (size, size):
                # Already baked (or natively square): boxes are already in the
                # target frame, so the transform is the identity. Existing
                # letterbox records are preserved instead of being overwritten
                # with the identity meta, which keeps a second bake byte-stable.
                meta: BakeMeta = (1.0, 0, 0)
                counters["images_already_at_target_size"] += 1
            else:
                canvas, scale, pad_x, pad_y = letterbox_image(opened, size, pad_value)
                canvas.save(image_path, "JPEG", quality=jpeg_quality)
                meta = (scale, pad_x, pad_y)
                counters["images_baked"] += 1
        scale, pad_x, pad_y = meta
        meta_by_image_id[int(image["id"])] = meta
        baked_images.append(
            {
                **image,
                "width": size,
                "height": size,
                "source_width": int(image.get("source_width", declared[0])),
                "source_height": int(image.get("source_height", declared[1])),
                "letterbox_scale": float(image.get("letterbox_scale", round(scale, 6))),
                "letterbox_pad_x": int(image.get("letterbox_pad_x", pad_x)),
                "letterbox_pad_y": int(image.get("letterbox_pad_y", pad_y)),
            }
        )

    baked_annotations: list[dict[str, Any]] = []
    per_source_images: Counter[str] = Counter()
    per_source_annotations: Counter[str] = Counter()
    for image in baked_images:
        per_source_images[str(image.get("source", "unknown"))] += 1
    source_by_image_id = {int(image["id"]): str(image.get("source", "unknown")) for image in baked_images}
    counters["annotations_before"] = len(coco["annotations"])
    for annotation in coco["annotations"]:
        if int(annotation["category_id"]) != SINGLE_CLASS_ID:
            raise SystemExit(
                f"{split_name} annotation {annotation['id']} has category id "
                f"{annotation['category_id']}, expected {SINGLE_CLASS_ID}; "
                "run 'uv run hold-build --force' first"
            )
        meta = meta_by_image_id.get(int(annotation["image_id"]))
        if meta is None:
            raise SystemExit(
                f"{split_name} annotation {annotation['id']} references unknown "
                f"image id {annotation['image_id']}"
            )
        mapped = map_box_to_letterbox(
            [float(value) for value in annotation["bbox"]], meta, size, counters
        )
        if mapped is None:
            continue
        baked_annotations.append(
            {
                **annotation,
                "id": len(baked_annotations) + 1,
                "bbox": mapped,
                "area": round(mapped[2] * mapped[3], 2),
            }
        )
        per_source_annotations[source_by_image_id[int(annotation["image_id"])]] += 1
    counters["annotations_after"] = len(baked_annotations)

    coco["info"]["description"] = (
        f"CyberSend hold detection, merged deduplicated {split_name} split, single "
        f"class, letterboxed {size}x{size} by hold-bake"
    )
    coco["images"] = baked_images
    coco["annotations"] = baked_annotations
    write_json(coco_path, coco)

    stats = {
        "images": len(baked_images),
        "images_baked": counters["images_baked"],
        "images_already_at_target_size": counters["images_already_at_target_size"],
        "annotations_before": counters["annotations_before"],
        "annotations_after": counters["annotations_after"],
        "annotations_clipped_to_canvas": counters["annotations_clipped_to_canvas"],
        "annotations_dropped_degenerate_bbox": counters["annotations_dropped_degenerate_bbox"],
        "per_source_images": dict(per_source_images),
        "per_source_annotations": dict(per_source_annotations),
        "annotations_sha256": sha256_file(coco_path),
    }
    return stats, meta_by_image_id


def _bake_color_sidecar(
    dataset_dir: Path,
    metas: dict[str, dict[int, BakeMeta]],
    size: int,
) -> dict[str, Any]:
    """Transform the pwals color sidecar boxes with their images; return counters."""
    sidecar_path = dataset_dir / "color_labels.json"
    counters: Counter[str] = Counter()
    if not sidecar_path.exists():
        return dict(counters)
    sidecar = read_json(sidecar_path)
    for split_name, rows in sidecar.get("splits", {}).items():
        meta_by_image_id = metas.get(split_name, {})
        for image_id, entries in rows.items():
            meta = meta_by_image_id.get(int(image_id))
            if meta is None:
                raise SystemExit(
                    f"color sidecar references unknown {split_name} image id {image_id}"
                )
            kept: list[dict[str, Any]] = []
            for entry in entries:
                counters["boxes_before"] += 1
                mapped = map_box_to_letterbox(
                    [float(value) for value in entry["bbox"]], meta, size, counters
                )
                if mapped is None:
                    continue
                counters["boxes_after"] += 1
                kept.append({**entry, "bbox": mapped})
            rows[image_id] = kept
    sidecar["bboxes_frame"] = (
        f"letterboxed {size}x{size} frame after hold-bake (transformed with the "
        "image; source pixels before the bake)"
    )
    write_json(sidecar_path, sidecar)
    return dict(counters)


def _verify_split(dataset_dir: Path, split_name: str, size: int) -> dict[str, Any]:
    """Check one baked split: frame, boxes, category ids, and manifest digests."""
    split_dir = dataset_dir / split_name
    coco_path, coco = _load_split(dataset_dir, split_name)
    images_by_id = {int(image["id"]): image for image in coco["images"]}
    problems: list[str] = []

    for image in coco["images"]:
        if int(image["width"]) != size or int(image["height"]) != size:
            problems.append(f"image {image['file_name']} is declared "
                            f"{image['width']}x{image['height']}, not {size}x{size}")
            continue
        if "source_width" not in image or "letterbox_pad_x" not in image:
            problems.append(f"image {image['file_name']} has no letterbox record")
        image_path = split_dir / image["file_name"]
        if not image_path.exists():
            problems.append(f"missing image file {image_path}")
            continue
        with Image.open(image_path) as opened:
            if opened.size != (size, size):
                problems.append(
                    f"image {image['file_name']} is {opened.size[0]}x{opened.size[1]} "
                    f"on disk, not {size}x{size}"
                )

    out_of_bounds = 0
    degenerate = 0
    for annotation in coco["annotations"]:
        if int(annotation["category_id"]) != SINGLE_CLASS_ID:
            problems.append(
                f"annotation {annotation['id']} has category id "
                f"{annotation['category_id']}, expected {SINGLE_CLASS_ID}"
            )
        image = images_by_id.get(int(annotation["image_id"]))
        if image is None:
            problems.append(f"annotation {annotation['id']} references unknown image id")
            continue
        x, y, box_width, box_height = [float(value) for value in annotation["bbox"]]
        if box_width < MIN_BOX_SIDE_PX or box_height < MIN_BOX_SIDE_PX:
            degenerate += 1
            problems.append(
                f"annotation {annotation['id']} is degenerate ({box_width}x{box_height})"
            )
        if x < -1e-6 or y < -1e-6 or x + box_width > size + 1e-6 or y + box_height > size + 1e-6:
            out_of_bounds += 1
            problems.append(f"annotation {annotation['id']} is outside the {size} canvas")

    return {
        "images": len(coco["images"]),
        "annotations": len(coco["annotations"]),
        "annotations_sha256": sha256_file(coco_path),
        "out_of_bounds": out_of_bounds,
        "degenerate": degenerate,
        "problems": problems,
    }


def verify(dataset_dir: Path, size: int = DEFAULT_IMAGE_SIZE) -> None:
    """Fail loudly unless every split is baked and consistent with the manifest."""
    manifest_path = dataset_dir / "manifest.json"
    if not manifest_path.exists():
        raise SystemExit(f"manifest not found: {manifest_path}; run 'uv run hold-build' first")
    manifest = read_json(manifest_path)
    bake = manifest.get("bake")
    if not isinstance(bake, dict):
        raise SystemExit(f"{manifest_path} has no 'bake' section; run 'uv run hold-bake' first")

    failed = False
    for split_name in SPLIT_NAMES:
        result = _verify_split(dataset_dir, split_name, size)
        recorded = manifest.get("splits", {}).get(split_name, {})
        if int(recorded.get("annotations", -1)) != result["annotations"]:
            result["problems"].append(
                f"manifest says {recorded.get('annotations')} annotations, "
                f"file has {result['annotations']}"
            )
        if recorded.get("annotations_sha256") != result["annotations_sha256"]:
            result["problems"].append("manifest annotations_sha256 does not match the file")
        status = "OK" if not result["problems"] else "FAIL"
        print(
            f"  [{split_name}] {status}: {result['images']} images at {size}x{size}, "
            f"{result['annotations']} annotations, {result['out_of_bounds']} out of bounds, "
            f"{result['degenerate']} degenerate"
        )
        for problem in result["problems"][:10]:
            print(f"    - {problem}")
        if result["problems"]:
            failed = True

    sidecar_path = dataset_dir / "color_labels.json"
    if sidecar_path.exists():
        sidecar = read_json(sidecar_path)
        sidecar_boxes = 0
        for rows in sidecar.get("splits", {}).values():
            for entries in rows.values():
                for entry in entries:
                    sidecar_boxes += 1
                    x, y, box_width, box_height = [float(value) for value in entry["bbox"]]
                    if (
                        x < -1e-6
                        or y < -1e-6
                        or x + box_width > size + 1e-6
                        or y + box_height > size + 1e-6
                    ):
                        failed = True
                        print(f"    - color sidecar box outside the canvas: {entry['bbox']}")
        print(f"  [color sidecar] {sidecar_boxes} boxes inside the {size} canvas")

    if failed:
        raise SystemExit("hold-bake --verify FAILED")
    print(f"verify OK: {dataset_dir} is baked ({size}x{size}, pad centered)")


def bake(
    dataset_dir: Path,
    size: int = DEFAULT_IMAGE_SIZE,
    pad_value: int = DEFAULT_PAD_VALUE,
    jpeg_quality: int = DEFAULT_JPEG_QUALITY,
) -> Path:
    """Bake every split of the merged dataset in place and update manifest.json."""
    manifest_path = dataset_dir / "manifest.json"
    if not manifest_path.exists():
        raise SystemExit(f"manifest not found: {manifest_path}; run 'uv run hold-build' first")
    manifest = read_json(manifest_path)
    previous_bake = manifest.get("bake") if isinstance(manifest.get("bake"), dict) else None

    print(f"Baking letterbox {size}x{size} (pad {pad_value}, centered) into {dataset_dir}")
    split_stats: dict[str, Any] = {}
    metas: dict[str, dict[int, BakeMeta]] = {}
    for split_name in SPLIT_NAMES:
        stats, meta_by_image_id = _bake_split(dataset_dir, split_name, size, pad_value, jpeg_quality)
        metas[split_name] = meta_by_image_id
        split_stats[split_name] = stats
        print(
            f"  {split_name}: {stats['images_baked']} images baked, "
            f"{stats['images_already_at_target_size']} already at target size, "
            f"annotations {stats['annotations_before']} -> {stats['annotations_after']} "
            f"({stats['annotations_clipped_to_canvas']} clipped, "
            f"{stats['annotations_dropped_degenerate_bbox']} degenerate dropped)"
        )
        # Split membership and per-source counts are unchanged by baking; only
        # the box coordinates and image records move into the 640 frame.
        recorded = manifest.setdefault("splits", {}).setdefault(split_name, {})
        recorded["images"] = stats["images"]
        recorded["annotations"] = stats["annotations_after"]
        recorded["per_source_images"] = stats["per_source_images"]
        recorded["per_source_annotations"] = stats["per_source_annotations"]
        recorded["annotations_sha256"] = stats["annotations_sha256"]

    sidecar_counters = _bake_color_sidecar(dataset_dir, metas, size)
    if sidecar_counters:
        print(
            f"  color sidecar: {sidecar_counters.get('boxes_before', 0)} boxes -> "
            f"{sidecar_counters.get('boxes_after', 0)} "
            f"({sidecar_counters.get('annotations_clipped_to_canvas', 0)} clipped, "
            f"{sidecar_counters.get('annotations_dropped_degenerate_bbox', 0)} dropped)"
        )

    # A pass that baked no images is a refresh (idempotent re-bake): keep the
    # original bake record, including the degenerate-box counts of the pass that
    # actually transformed the data, and refresh only current-truth fields.
    is_refresh = previous_bake is not None and all(
        stats["images_baked"] == 0 for stats in split_stats.values()
    )
    if is_refresh:
        previous_splits = previous_bake.get("splits", {})
        for split_name, stats in split_stats.items():
            previous = previous_splits.get(split_name)
            if isinstance(previous, dict):
                split_stats[split_name] = {
                    **previous,
                    "annotations_after": stats["annotations_after"],
                    "per_source_images": stats["per_source_images"],
                    "per_source_annotations": stats["per_source_annotations"],
                    "annotations_sha256": stats["annotations_sha256"],
                }
        previous_sidecar = previous_bake.get("color_sidecar")
        if isinstance(previous_sidecar, dict):
            sidecar_counters = previous_sidecar
        print("  refresh pass: original bake record kept, digests updated")

    now = datetime.now(timezone.utc).isoformat()
    bake_section: dict[str, Any] = {
        "applied_at": (previous_bake or {}).get("applied_at", now),
        "pipeline": "hold-bake",
        "letterbox": {
            "size": size,
            "pad_value": pad_value,
            "alignment": "centered",
            "content_rounding": "halves up (JavaScript Math.round parity)",
            "resampling": "BICUBIC",
            "color_space": "RGB",
            "geometry_matches": "tools/eval/src/preprocess.ts letterboxGeometryFor",
        },
        "annotation_transform": (
            "bbox scaled by letterbox_scale, offset by letterbox_pad_x/y, clipped to the "
            f"{size} canvas, rounded to 2 decimals; boxes under {MIN_BOX_SIDE_PX:.0f} px on a "
            "side dropped and counted; image records keep source_width, source_height, "
            "letterbox_scale, letterbox_pad_x, letterbox_pad_y"
        ),
        "note": (
            "annotations_sha256 values in 'splits' are POST-bake digests and differ from the "
            "hold-build digests; split membership (including the frozen test split) is unchanged"
        ),
        "color_sidecar": sidecar_counters,
        "splits": split_stats,
    }
    if is_refresh:
        bake_section["refreshed_at"] = now
    manifest["bake"] = bake_section
    write_json(manifest_path, manifest)
    print(f"Manifest updated: {manifest_path}")
    print("Next: run 'uv run hold-bake --verify' to re-check the baked dataset.")
    return manifest_path


def main() -> None:
    """Entry point for the hold-bake console script."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-dir", type=Path, default=DEFAULT_DATASET_DIR)
    parser.add_argument("--image-size", type=int, default=DEFAULT_IMAGE_SIZE)
    parser.add_argument("--pad-value", type=int, default=DEFAULT_PAD_VALUE)
    parser.add_argument("--jpeg-quality", type=int, default=DEFAULT_JPEG_QUALITY)
    parser.add_argument(
        "--verify",
        action="store_true",
        help="check the baked dataset and manifest without writing anything",
    )
    args = parser.parse_args()

    if args.verify:
        verify(args.dataset_dir, args.image_size)
    else:
        bake(
            dataset_dir=args.dataset_dir,
            size=args.image_size,
            pad_value=args.pad_value,
            jpeg_quality=args.jpeg_quality,
        )


if __name__ == "__main__":
    main()
