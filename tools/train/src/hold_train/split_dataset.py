"""Seeded 60/20/20 photo-level train/val/test split with letterbox baking.

Reads a COCO file (from hold-convert), groups images by source photo identity so
Roboflow augmented variants of one photo never leak across splits, shuffles groups with
a fixed seed, and materializes the RF-DETR "Roboflow style" dataset layout:

    prepared/train/images/*.jpg + _annotations.coco.json
    prepared/valid/images/*.jpg + _annotations.coco.json
    prepared/test/images/*.jpg  + _annotations.coco.json

Each image is written already letterboxed to 640x640 with pad value 114 (centered,
BICUBIC resampling), and boxes are mapped into the letterboxed frame. RF-DETR's own
eval transform is Resize((640, 640)), which becomes an identity on this data, so the
shared app/harness preprocess in tools/eval/src/preprocess.ts (letterbox 640, pad 114,
ImageNet normalization) matches training exactly.

The split itself is deterministic given (seed, input COCO, grouping rule). A
split_manifest.json records seed, ratios, counts, per-split photo groups, and hashes.
"""

from __future__ import annotations

import argparse
import random
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from PIL import Image

from .common import DATASETS_DIR, ensure_dir, read_json, sha256_file, write_json
from .dataset_download import _photo_group_key

DEFAULT_SEED = 20261019
DEFAULT_IMAGE_SIZE = 640
DEFAULT_PAD_VALUE = 114
SPLIT_NAMES = ("train", "valid", "test")


def letterbox_image(image: Image.Image, image_size: int, pad_value: int) -> tuple[Image.Image, float, int, int]:
    """Fit image into image_size x image_size with aspect preserved and centered padding.

    Returns (letterboxed image, scale, pad_x, pad_y) where pad offsets are the top-left
    corner of the original image inside the padded canvas.
    """
    width, height = image.size
    scale = min(image_size / width, image_size / height)
    new_width = max(1, round(width * scale))
    new_height = max(1, round(height * scale))
    resized = image.convert("RGB").resize((new_width, new_height), Image.BICUBIC)
    pad_x = (image_size - new_width) // 2
    pad_y = (image_size - new_height) // 2
    canvas = Image.new("RGB", (image_size, image_size), (pad_value, pad_value, pad_value))
    canvas.paste(resized, (pad_x, pad_y))
    return canvas, scale, pad_x, pad_y


def map_box_to_letterbox(
    bbox: list[float], scale: float, pad_x: int, pad_y: int, image_size: int
) -> list[float] | None:
    """Map a COCO xywh box from source pixels into the letterboxed frame."""
    x, y, box_w, box_h = bbox
    new_x = x * scale + pad_x
    new_y = y * scale + pad_y
    new_w = box_w * scale
    new_h = box_h * scale
    new_x = max(0.0, min(new_x, float(image_size)))
    new_y = max(0.0, min(new_y, float(image_size)))
    new_w = min(new_w, float(image_size) - new_x)
    new_h = min(new_h, float(image_size) - new_y)
    if new_w < 1.0 or new_h < 1.0:
        return None
    return [round(new_x, 2), round(new_y, 2), round(new_w, 2), round(new_h, 2)]


def _allocate_groups(
    groups: dict[str, list[int]], seed: int, train_ratio: float, val_ratio: float
) -> dict[str, list[str]]:
    """Deterministically assign photo groups to splits by shuffled cumulative count."""
    rng = random.Random(seed)
    keys = sorted(groups)
    rng.shuffle(keys)
    total = sum(len(groups[key]) for key in keys)
    train_cut = total * train_ratio
    val_cut = train_cut + total * val_ratio
    allocation: dict[str, list[str]] = {name: [] for name in SPLIT_NAMES}
    running = 0
    for key in keys:
        if running < train_cut:
            allocation["train"].append(key)
        elif running < val_cut:
            allocation["valid"].append(key)
        else:
            allocation["test"].append(key)
        running += len(groups[key])
    return allocation


def split_and_prepare(
    coco_path: Path,
    dataset_dir: Path,
    output_dir: Path,
    seed: int,
    train_ratio: float,
    val_ratio: float,
    test_ratio: float,
    image_size: int,
    pad_value: int,
) -> Path:
    """Split by photo and write letterboxed RF-DETR layout plus split_manifest.json."""
    total_ratio = train_ratio + val_ratio + test_ratio
    if abs(total_ratio - 1.0) > 1e-9:
        raise ValueError(f"split ratios must sum to 1.0, got {total_ratio}")

    coco = read_json(coco_path)
    images_by_id = {image["id"]: image for image in coco["images"]}
    annotations_by_image: dict[int, list[dict[str, Any]]] = {}
    for annotation in coco["annotations"]:
        annotations_by_image.setdefault(annotation["image_id"], []).append(annotation)

    groups: dict[str, list[int]] = {}
    for image in coco["images"]:
        group_key = _photo_group_key(Path(image["file_name"]).name)
        groups.setdefault(group_key, []).append(image["id"])

    allocation = _allocate_groups(groups, seed, train_ratio, val_ratio)
    print(
        f"Split with seed={seed}: "
        + ", ".join(f"{name}={len(allocation[name])} photos" for name in SPLIT_NAMES)
    )

    manifest_splits: dict[str, Any] = {}
    for split_name in SPLIT_NAMES:
        split_image_dir = ensure_dir(output_dir / split_name / "images")
        split_images: list[dict[str, Any]] = []
        split_annotations: list[dict[str, Any]] = []
        next_image_id = 0
        next_annotation_id = 0
        for group_key in sorted(allocation[split_name]):
            for source_image_id in sorted(groups[group_key]):
                image = images_by_id[source_image_id]
                source_path = dataset_dir / image["file_name"]
                if not source_path.exists():
                    print(f"  WARNING: missing image file {source_path}, skipping")
                    continue
                with Image.open(source_path) as opened:
                    canvas, scale, pad_x, pad_y = letterbox_image(opened, image_size, pad_value)
                output_name = Path(image["file_name"]).name
                canvas.save(split_image_dir / output_name, "JPEG", quality=92)
                next_image_id += 1
                split_images.append(
                    {
                        "id": next_image_id,
                        "file_name": f"images/{output_name}",
                        "width": image_size,
                        "height": image_size,
                        "source_file_name": image["file_name"],
                        "source_width": image["width"],
                        "source_height": image["height"],
                        "letterbox_scale": round(scale, 6),
                        "letterbox_pad_x": pad_x,
                        "letterbox_pad_y": pad_y,
                    }
                )
                for annotation in annotations_by_image.get(source_image_id, []):
                    mapped = map_box_to_letterbox(annotation["bbox"], scale, pad_x, pad_y, image_size)
                    if mapped is None:
                        continue
                    next_annotation_id += 1
                    split_annotations.append(
                        {
                            "id": next_annotation_id,
                            "image_id": next_image_id,
                            "category_id": 1,
                            "bbox": mapped,
                            "area": round(mapped[2] * mapped[3], 2),
                            "iscrowd": 0,
                        }
                    )
        split_coco = {
            "info": {
                "description": "CyberSend hold detection, letterboxed 640 training split",
                "version": "1.0",
            },
            "licenses": [],
            "categories": coco["categories"],
            "images": split_images,
            "annotations": split_annotations,
        }
        split_coco_path = output_dir / split_name / "_annotations.coco.json"
        write_json(split_coco_path, split_coco)
        manifest_splits[split_name] = {
            "photos": len(allocation[split_name]),
            "images": len(split_images),
            "instances": len(split_annotations),
            "photo_groups": sorted(allocation[split_name]),
            "annotations_sha256": sha256_file(split_coco_path),
        }
        print(
            f"  {split_name}: {len(split_images)} images, {len(split_annotations)} instances "
            f"-> {split_coco_path}"
        )

    manifest = {
        "created_at": datetime.now(timezone.utc).isoformat(),
        "source_coco": str(coco_path.relative_to(dataset_dir.parent.parent) if coco_path.is_relative_to(dataset_dir.parent.parent) else coco_path),
        "source_coco_sha256": sha256_file(coco_path),
        "seed": seed,
        "ratios": {"train": train_ratio, "valid": val_ratio, "test": test_ratio},
        "grouping_rule": "Roboflow .rf. augmented variants grouped with source photo (case-insensitive stem)",
        "letterbox": {
            "size": image_size,
            "pad_value": pad_value,
            "alignment": "centered",
            "resampling": "BICUBIC",
            "color_space": "RGB",
        },
        "splits": manifest_splits,
    }
    manifest_path = dataset_dir / "split_manifest.json"
    write_json(manifest_path, manifest)
    print(f"Split manifest written to {manifest_path}")
    return manifest_path


def main() -> None:
    """Entry point for the hold-split console script."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-dir", type=Path, default=DATASETS_DIR / "climbinst_smoke")
    parser.add_argument("--coco", type=Path, default=None, help="defaults to <dataset-dir>/coco/instances.json")
    parser.add_argument("--output", type=Path, default=None, help="defaults to <dataset-dir>/prepared")
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    parser.add_argument("--train-ratio", type=float, default=0.6)
    parser.add_argument("--val-ratio", type=float, default=0.2)
    parser.add_argument("--test-ratio", type=float, default=0.2)
    parser.add_argument("--image-size", type=int, default=DEFAULT_IMAGE_SIZE)
    parser.add_argument("--pad-value", type=int, default=DEFAULT_PAD_VALUE)
    args = parser.parse_args()

    coco_path = args.coco or (args.dataset_dir / "coco" / "instances.json")
    output_dir = args.output or (args.dataset_dir / "prepared")
    split_and_prepare(
        coco_path=coco_path,
        dataset_dir=args.dataset_dir,
        output_dir=output_dir,
        seed=args.seed,
        train_ratio=args.train_ratio,
        val_ratio=args.val_ratio,
        test_ratio=args.test_ratio,
        image_size=args.image_size,
        pad_value=args.pad_value,
    )


if __name__ == "__main__":
    main()
