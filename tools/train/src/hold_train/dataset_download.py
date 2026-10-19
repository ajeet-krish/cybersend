"""Download datasets for the CyberSend hold detector training pipeline.

Primary source: Blackcreed "Climbing Holds and Volumes" (Roboflow Universe, CC BY 4.0,
1717 images, 2 classes). Roboflow programmatic downloads require an API key. The exact
command, once a key exists, is:

    export ROBOFLOW_API_KEY="<your key from https://app.roboflow.com/settings/api>"
    curl -L "https://api.roboflow.com/dataset/blackcreed/climbing-holds-and-volumes/download/?format=coco&api_key=$ROBOFLOW_API_KEY" -o /tmp/blackcreed_coco.zip

This script runs that download (and extraction) automatically when ROBOFLOW_API_KEY is
set. Keys are never hardcoded and never written to disk by this project.

Fallback (no API key available): a small, clearly labeled smoke test subset of
ClimbVision/ClimbInst on Hugging Face. ClimbInst is declared CC BY-NC-SA 4.0 and its
license chain is unclear (it incorporates "Climbing Holds and Volumes" CC BY 4.0
material and "Indoor Climbing Gym Hold and Route Segmentation" CC BY-NC-SA 4.0
material). It exists only to prove the pipeline end to end and must never ship in a
build or in the final Phase 4 training run.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
import urllib.request
import zipfile
from collections import Counter
from pathlib import Path
from typing import Any

from .common import DATASETS_DIR, SINGLE_CLASS_NAME, ensure_dir, read_json, write_json

ROBOFLOW_DATASET_SLUG = "blackcreed/climbing-holds-and-volumes"
ROBOFLOW_API_KEY_ENV = "ROBOFLOW_API_KEY"
BLACKCREED_DIR = DATASETS_DIR / "blackcreed_climbing_holds"
CLIMBINST_DIR = DATASETS_DIR / "climbinst_smoke"

HF_DATASET_ID = "ClimbVision/ClimbInst"
HF_API = "https://huggingface.co/api/datasets"
HF_RAW = f"https://huggingface.co/datasets/{HF_DATASET_ID}"
HF_SPLITS = ("train", "validation", "test")

# Keeps smoke downloads small enough for a laptop while still exercising the full path.
DEFAULT_MAX_IMAGE_BYTES = 250_000
DEFAULT_IMAGE_LIMIT = 150


def _http_get(url: str) -> bytes:
    """Fetch a URL with a descriptive user agent and no auth headers."""
    request = urllib.request.Request(url, headers={"User-Agent": "cybersend-train/0.1"})
    with urllib.request.urlopen(request, timeout=60) as response:  # noqa: S310 (trusted hosts only)
        return response.read()


def _http_download(url: str, dest: Path) -> None:
    """Download a URL to dest, printing progress for large files."""
    request = urllib.request.Request(url, headers={"User-Agent": "cybersend-train/0.1"})
    with urllib.request.urlopen(request, timeout=120) as response:  # noqa: S310 (trusted hosts only)
        ensure_dir(dest.parent)
        with dest.open("wb") as handle:
            while True:
                chunk = response.read(1 << 16)
                if not chunk:
                    break
                handle.write(chunk)
    print(f"  downloaded {dest.name} ({dest.stat().st_size} bytes)")


def _hf_tree(split_dir: str) -> list[dict[str, Any]]:
    """List one subtree of the HF dataset repo via the tree API (paginated)."""
    entries: list[dict[str, Any]] = []
    url: str | None = f"{HF_API}/{HF_DATASET_ID}/tree/main/{split_dir}?limit=1000"
    while url:
        request = urllib.request.Request(url, headers={"User-Agent": "cybersend-train/0.1"})
        with urllib.request.urlopen(request, timeout=60) as response:  # noqa: S310 (trusted host)
            body = response.read()
            link_header = response.headers.get("Link", "")
        entries.extend(json_loads_bytes(body))
        match = re.search(r'<([^>]+)>;\s*rel="next"', link_header)
        url = match.group(1) if match else None
    return [entry for entry in entries if entry.get("type") == "file"]


def json_loads_bytes(body: bytes) -> list[dict[str, Any]]:
    """Parse a JSON array payload from bytes."""
    import json

    parsed = json.loads(body.decode("utf-8"))
    if not isinstance(parsed, list):
        raise ValueError("expected a JSON array from the HF tree API")
    return parsed


def _photo_group_key(filename: str) -> str:
    """Group Roboflow augmented variants (name.rf.HASH.jpg) with their source photo."""
    stem = filename
    for suffix in (".jpg", ".jpeg", ".png"):
        if stem.lower().endswith(suffix):
            stem = stem[: -len(suffix)]
            break
    if ".rf." in stem:
        stem = stem.split(".rf.", 1)[0]
    return stem.lower()


def merge_coco_splits(
    dataset_dir: Path, source_splits: tuple[str, ...] = ("train", "valid", "test")
) -> Path:
    """Merge Roboflow-style per-split COCO files into a single coco/instances.json.

    Roboflow COCO exports ship train/, valid/ (or validation/), test/ each with an
    _annotations.coco.json, with file_name paths relative to the split folder.
    hold-split expects one COCO file with file_name paths relative to the dataset
    directory and a single "hold" class (the project trains one detector class), so
    this normalizes paths, renumbers ids, and unifies every category into "hold" while
    recording the raw category counts for transparency.
    """
    images: list[dict[str, Any]] = []
    annotations: list[dict[str, Any]] = []
    raw_categories: Counter[str] = Counter()
    next_image_id = 0
    next_annotation_id = 0

    for split in source_splits:
        coco_path = dataset_dir / split / "_annotations.coco.json"
        if not coco_path.exists():
            print(f"  skipping missing split file {coco_path}")
            continue
        coco = read_json(coco_path)
        category_names = {int(category["id"]): str(category["name"]) for category in coco.get("categories", [])}
        id_map: dict[int, int] = {}
        for image in coco.get("images", []):
            next_image_id += 1
            id_map[int(image["id"])] = next_image_id
            source_name = str(image["file_name"])
            images.append(
                {
                    "id": next_image_id,
                    "file_name": f"{split}/{Path(source_name).name}",
                    "width": image["width"],
                    "height": image["height"],
                }
            )
        for annotation in coco.get("annotations", []):
            source_image_id = int(annotation["image_id"])
            mapped_image_id = id_map.get(source_image_id)
            if mapped_image_id is None:
                continue
            raw_categories[category_names.get(int(annotation.get("category_id", 0)), "unknown")] += 1
            next_annotation_id += 1
            bbox = [float(value) for value in annotation["bbox"]]
            annotations.append(
                {
                    "id": next_annotation_id,
                    "image_id": mapped_image_id,
                    "category_id": 1,
                    "bbox": bbox,
                    "area": float(annotation.get("area", bbox[2] * bbox[3])),
                    "iscrowd": int(annotation.get("iscrowd", 0)),
                }
            )
        print(f"  merged {split}: {len(id_map)} images")

    coco = {
        "info": {
            "description": "CyberSend hold detection, merged Roboflow splits, single class",
            "version": "1.0",
        },
        "licenses": [],
        "categories": [{"id": 1, "name": SINGLE_CLASS_NAME, "supercategory": "climb"}],
        "images": images,
        "annotations": annotations,
    }
    output_path = dataset_dir / "coco" / "instances.json"
    write_json(output_path, coco)
    print(
        f"Merged {len(images)} images, {len(annotations)} instances -> {output_path}. "
        f"Raw categories unified into class '{SINGLE_CLASS_NAME}': {dict(raw_categories)}"
    )
    return output_path


def download_blackcreed(api_key: str) -> Path:
    """Download the Blackcreed dataset from Roboflow using the user's API key."""
    print(f"Downloading Blackcreed '{ROBOFLOW_DATASET_SLUG}' from Roboflow (COCO zip)...")
    url = (
        f"https://api.roboflow.com/dataset/{ROBOFLOW_DATASET_SLUG}/download/"
        f"?format=coco&api_key={api_key}"
    )
    zip_path = BLACKCREED_DIR / "blackcreed_coco.zip"
    try:
        _http_download(url, zip_path)
    except OSError as error:
        print(f"Roboflow download failed: {error}", file=sys.stderr)
        print(
            "Check the workspace/dataset slug against the Universe page and verify the API key.",
            file=sys.stderr,
        )
        raise
    with zipfile.ZipFile(zip_path) as archive:
        archive.extractall(BLACKCREED_DIR)
    print(f"Extracted into {BLACKCREED_DIR}")
    merge_coco_splits(BLACKCREED_DIR)
    return BLACKCREED_DIR


def download_climbinst_smoke(max_image_bytes: int, limit: int) -> Path:
    """Download a small subset of ClimbInst as a clearly labeled smoke stand-in only."""
    print("ROBOFLOW_API_KEY not set. Falling back to the ClimbInst smoke stand-in subset.")
    print(f"Downloading up to {limit} images of at most {max_image_bytes} bytes each "
          f"from HF {HF_DATASET_ID} (CC BY-NC-SA 4.0, license chain unclear, smoke only).")

    selected_images: list[dict[str, Any]] = []
    for split in HF_SPLITS:
        entries = _hf_tree(f"{split}/images")
        small = [entry for entry in entries if entry.get("size", 0) <= max_image_bytes]
        small.sort(key=lambda entry: entry["path"])
        selected_images.extend(small[: max(limit // len(HF_SPLITS), 1)])
    print(f"Selected {len(selected_images)} images across splits "
          f"(groups: {len({_photo_group_key(Path(e['path']).name) for e in selected_images})}).")

    for entry in selected_images:
        source = f"{HF_RAW}/resolve/main/{entry['path']}"
        _http_download(source, CLIMBINST_DIR / entry["path"])

    # Annotations for every selected image.
    for split in HF_SPLITS:
        wanted = {
            Path(entry["path"]).stem
            for entry in selected_images
            if Path(entry["path"]).parent.parent.name == split
        }
        entries = _hf_tree(f"{split}/annotations")
        for entry in entries:
            if Path(entry["path"]).stem in wanted:
                source = f"{HF_RAW}/resolve/main/{entry['path']}"
                _http_download(source, CLIMBINST_DIR / entry["path"])

    # License and provenance records live next to the data, per project convention.
    _http_download(f"{HF_RAW}/raw/main/LICENSE", CLIMBINST_DIR / "LICENSE")
    _http_download(f"{HF_RAW}/raw/main/README.md", CLIMBINST_DIR / "DATASET_README.md")
    write_json(
        CLIMBINST_DIR / "NOTICE.json",
        {
            "dataset": HF_DATASET_ID,
            "declared_license": "CC BY-NC-SA 4.0",
            "license_chain": "unclear (incorporates CC BY 4.0 and CC BY-NC-SA 4.0 sources)",
            "usage": "smoke test stand-in only, never shippable, never used for Phase 4 release training",
            "sources": [
                "Indoor Climbing Gym Hold and Route Segmentation (CC BY-NC-SA 4.0)",
                "Climbing Holds and Volumes (CC BY 4.0)",
            ],
            "image_selection": {
                "max_image_bytes": max_image_bytes,
                "limit": limit,
                "grouping": "Roboflow .rf. augmented variants grouped with source photo",
            },
        },
    )
    print(f"ClimbInst smoke subset ready under {CLIMBINST_DIR}")
    return CLIMBINST_DIR


def main() -> None:
    """Entry point for the hold-download console script."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--dataset",
        choices=("auto", "blackcreed", "climbinst_smoke"),
        default="auto",
        help="auto uses Blackcreed when ROBOFLOW_API_KEY is set, otherwise the ClimbInst smoke subset",
    )
    parser.add_argument("--max-image-bytes", type=int, default=DEFAULT_MAX_IMAGE_BYTES)
    parser.add_argument("--limit", type=int, default=DEFAULT_IMAGE_LIMIT)
    args = parser.parse_args()

    api_key = os.environ.get(ROBOFLOW_API_KEY_ENV, "")

    if args.dataset == "blackcreed":
        if not api_key:
            raise SystemExit(
                f"{ROBOFLOW_API_KEY_ENV} is required for the Blackcreed download. "
                'Set it with: export ROBOFLOW_API_KEY="<your key>"'
            )
        download_blackcreed(api_key)
        return

    if args.dataset == "climbinst_smoke":
        download_climbinst_smoke(args.max_image_bytes, args.limit)
        return

    # auto
    if api_key:
        download_blackcreed(api_key)
    else:
        print(
            f"No {ROBOFLOW_API_KEY_ENV} found. Blackcreed (Roboflow Universe, CC BY 4.0) "
            "needs a key for programmatic download. To fetch it later:\n"
            '  export ROBOFLOW_API_KEY="<your key from https://app.roboflow.com/settings/api>"\n'
            '  curl -L "https://api.roboflow.com/dataset/blackcreed/climbing-holds-and-volumes/'
            'download/?format=coco&api_key=$ROBOFLOW_API_KEY" -o /tmp/blackcreed_coco.zip\n'
        )
        download_climbinst_smoke(args.max_image_bytes, args.limit)


if __name__ == "__main__":
    main()
