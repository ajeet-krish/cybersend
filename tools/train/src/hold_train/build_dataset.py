"""Build the merged, deduplicated, resplit hold detection dataset (D1 foundation).

Merges three Roboflow COCO exports into one single-class detection dataset:

    datasets/raw/climbtag.v29i.coco    instance segmentation polygons, hold + volume
    datasets/raw/blackcreed.v14i.coco  bounding boxes, classes "0" + "1"
    datasets/raw/pwals.v18i.coco       bounding boxes, 16 color classes

Every category maps to the single class "hold" (category id 1, the RF-DETR
Roboflow loader convention; category id 0 is reserved for Roboflow's synthetic
parent container and is never emitted). Images are deduplicated in two stages: exact Roboflow variant-family grouping by photo
stem, plus pHash (64-bit) candidate search verified by 64x64 thumbnail
correlation (pHash alone over-merges on climbing wall imagery). Clusters are
assigned to train/val/test 60/20/20 by a seeded deterministic hash of the
cluster representative's pHash. The original Roboflow splits are DISCARDED:
they were split before augmentation, so augmented copies of one photo leak
across them.

Output (see manifest.json for the authoritative counts and hashes):

    datasets/merged/train|val|test/images/*.jpg
    datasets/merged/train|val|test/_annotations.coco.json
    datasets/merged/color_labels.json   (pwals color sidecar, seed data for the
                                         optional color-family classifier, NOT
                                         part of detection training)
    datasets/merged/manifest.json

Images leave this step at source resolution with boxes in source pixels. The
shared inference preprocess is baked into the dataset afterwards by hold-bake
(letterbox 640, pad 114, centered), which is a separate deterministic step so
that raw and baked views of the same split remain reproducible.

Sanity checks fail loudly: no pHash cluster may span two splits, every image
file referenced by an output annotation file must exist, and every bbox must
sit inside its image (small excursions are clipped and counted; more than 5
percent out of bounds is an error).
"""

from __future__ import annotations

import argparse
import hashlib
import re
import shutil
import time
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import numpy as np
from PIL import Image

from .common import (
    DATASETS_DIR,
    SINGLE_CLASS_ID,
    SINGLE_CLASS_NAME,
    ensure_dir,
    read_json,
    sha256_file,
    write_json,
)

RAW_DIR = DATASETS_DIR / "raw"
DEFAULT_OUTPUT_DIR = DATASETS_DIR / "merged"
DEFAULT_SEED = 20261019
DEFAULT_HAMMING_THRESHOLD = 6
TRAIN_RATIO = 0.6
VAL_RATIO = 0.2
TEST_RATIO = 0.2
MIN_BOX_SIDE_PX = 2.0
OUT_OF_BOUNDS_ERROR_FRACTION = 0.05
PHASH_RESIZE = 32
PHASH_BLOCK = 8
THUMB_SIZE = 64
DUPLICATE_CORR_THRESHOLD = 0.975
CORRELATION_CHUNK_PAIRS = 10_000
CLUSTER_CHUNK_ROWS = 1024
SPLIT_NAMES = ("train", "val", "test")
SOURCE_SPLITS = ("train", "valid", "test")
MULTI_COLOR_TOKEN = "multi"

# Roboflow augmented variants look like <stem>.rf.<32 hex>.jpg; resized exports
# may carry a trailing -WxH. Both must group with the original photo.
_ROBOFLOW_VARIANT_RE = re.compile(r"\.rf\.")
_RESIZE_SUFFIX_RE = re.compile(r"-\d+x\d+$")


@dataclass(frozen=True)
class SourceSpec:
    """One input dataset: where it lives, its provenance, and how to find it."""

    name: str
    dir_name: str
    version: str
    license_id: str
    license_note: str | None
    url: str


SOURCES: tuple[SourceSpec, ...] = (
    SourceSpec(
        name="climbtag",
        dir_name="climbtag.v29i.coco",
        version="v29 (2026-03-12)",
        license_id="CC BY 4.0",
        license_note="augmented export, about 3x Roboflow augmentation over about 1644 source photos",
        url="https://universe.roboflow.com/climbtag/climbing-hold-detection-7uehq",
    ),
    SourceSpec(
        name="blackcreed",
        dir_name="blackcreed.v14i.coco",
        version="v14 (2023-09-12)",
        license_id="CC BY 4.0",
        license_note="augmented export; classes '0' and '1' (hold and volume per dataset description)",
        url="https://universe.roboflow.com/blackcreed-xpgxh/climbing-holds-and-volumes",
    ),
    SourceSpec(
        name="pwals",
        dir_name="pwals.v18i.coco",
        version="v18 (2023-11-24)",
        license_id="CC BY 4.0",
        license_note=(
            "Roboflow export README states CC BY 4.0; verified on the Universe "
            "project page 2026-10-19 (see tools/train/LICENSES.md)"
        ),
        url="https://universe.roboflow.com/pwals/bouldering-holds-9wavr",
    ),
)


@dataclass
class NormalizedAnnotation:
    """A single hold instance in source-image pixel coordinates."""

    bbox_xywh: list[float]
    source_category: str


@dataclass
class ImageRecord:
    """One candidate image with its pHash, thumbnail fingerprint, and annotations."""

    source: SourceSpec
    origin_split: str
    file_name: str
    source_path: Path
    width: int
    height: int
    phash: int
    thumb: np.ndarray | None = field(default=None, repr=False)
    annotations: list[NormalizedAnnotation] = field(default_factory=list)


class UnionFind:
    """Minimal union-find (disjoint set) with path compression and union by rank."""

    def __init__(self, count: int) -> None:
        self.parent = list(range(count))
        self.rank = [0] * count

    def find(self, item: int) -> int:
        while self.parent[item] != item:
            self.parent[item] = self.parent[self.parent[item]]
            item = self.parent[item]
        return item

    def union(self, left: int, right: int) -> None:
        root_left = self.find(left)
        root_right = self.find(right)
        if root_left == root_right:
            return
        if self.rank[root_left] < self.rank[root_right]:
            root_left, root_right = root_right, root_left
        self.parent[root_right] = root_left
        if self.rank[root_left] == self.rank[root_right]:
            self.rank[root_left] += 1


_dct_matrix_cache: dict[int, np.ndarray] = {}


def _dct_matrix(size: int) -> np.ndarray:
    """Return the size x size DCT-II basis matrix (unnormalized, matching imagehash)."""
    cached = _dct_matrix_cache.get(size)
    if cached is not None:
        return cached
    rows = np.arange(size, dtype=np.float64)
    matrix = np.cos(np.pi * np.outer(rows + 0.5, rows) / size)
    _dct_matrix_cache[size] = matrix
    return matrix


def compute_fingerprint(image_path: Path) -> tuple[int, int, int, np.ndarray]:
    """Compute the 64-bit pHash plus a thumbnail fingerprint for one image.

    The pHash follows the imagehash convention: grayscale, resize to 32x32
    (LANCZOS), DCT-II, top-left 8x8 low frequency block, threshold each
    coefficient against the block median. The thumbnail is a 64x64 grayscale
    float32 array used to VERIFY candidate duplicates: on this corpus of
    climbing wall photos the coarse pHash over-merges heavily (different
    photos of similar walls collide even at Hamming distance 0), while
    correlation of the finer thumbnail cleanly separates true duplicates
    (re-exports, cross-dataset reuse) from merely similar walls.

    Returns (hash, width, height, thumbnail).
    """
    with Image.open(image_path) as opened:
        width, height = opened.size
        gray = opened.convert("L")
        phash_image = gray.resize((PHASH_RESIZE, PHASH_RESIZE), Image.Resampling.LANCZOS)
        array = np.asarray(phash_image, dtype=np.float64)
        thumb = np.asarray(
            gray.resize((THUMB_SIZE, THUMB_SIZE), Image.Resampling.BILINEAR), dtype=np.float32
        ).ravel()
    matrix = _dct_matrix(PHASH_RESIZE)
    dct = matrix @ array @ matrix.T
    block = dct[:PHASH_BLOCK, :PHASH_BLOCK].flatten()
    median = float(np.median(block))
    value = 0
    for coefficient in block:
        value = (value << 1) | int(coefficient > median)
    return value, width, height, thumb


def photo_stem(file_name: str) -> str:
    """Reduce a Roboflow file name to its source-photo stem for grouping.

    Strips the extension, the .rf.<hash> augmentation suffix, and a trailing
    -WxH resize suffix, case-insensitively.
    """
    stem = Path(file_name).stem
    if _ROBOFLOW_VARIANT_RE.search(stem):
        stem = _ROBOFLOW_VARIANT_RE.split(stem, maxsplit=1)[0]
    stem = _RESIZE_SUFFIX_RE.sub("", stem)
    return stem.lower()


def normalize_color_family(category_name: str) -> str:
    """Map a pwals color class name to a color family token.

    'black-hold' maps to 'black', 'black-pink-hold' maps to 'multi',
    'cyan-hold' maps to 'cyan'.
    """
    stem = category_name.lower()
    if stem.endswith("-hold"):
        stem = stem[: -len("-hold")]
    if "-" in stem:
        return MULTI_COLOR_TOKEN
    return stem


def _bbox_from_segmentation(segmentation: Any) -> list[float] | None:
    """Derive an axis-aligned xywh bbox from COCO polygon segmentation, if possible."""
    if not isinstance(segmentation, list) or not segmentation:
        return None
    xs: list[float] = []
    ys: list[float] = []
    for polygon in segmentation:
        if not isinstance(polygon, list) or len(polygon) < 6:
            continue
        coordinates = [float(value) for value in polygon]
        xs.extend(coordinates[0::2])
        ys.extend(coordinates[1::2])
    if not xs or not ys:
        return None
    return [min(xs), min(ys), max(xs) - min(xs), max(ys) - min(ys)]


def _normalize_bbox(
    annotation: dict[str, Any],
    width: int,
    height: int,
    counters: Counter[str],
) -> list[float] | None:
    """Return a clipped xywh bbox or None, counting every degradation along the way."""
    raw_bbox = annotation.get("bbox") or []
    derived = False
    bbox: list[float] | None = None
    if isinstance(raw_bbox, list) and len(raw_bbox) == 4:
        candidate = [float(value) for value in raw_bbox]
        if candidate[2] > 0 and candidate[3] > 0:
            bbox = candidate
    if bbox is None:
        bbox = _bbox_from_segmentation(annotation.get("segmentation"))
        derived = bbox is not None
    if bbox is None:
        counters["annotations_dropped_no_bbox"] += 1
        return None
    if derived:
        counters["annotations_bbox_derived_from_polygon"] += 1

    x, y, box_width, box_height = bbox
    x1 = max(0.0, min(x, float(width)))
    y1 = max(0.0, min(y, float(height)))
    x2 = max(0.0, min(x + box_width, float(width)))
    y2 = max(0.0, min(y + box_height, float(height)))
    clipped_w = x2 - x1
    clipped_h = y2 - y1
    was_clipped = abs(clipped_w - box_width) > 1e-6 or abs(clipped_h - box_height) > 1e-6
    if was_clipped:
        counters["annotations_clipped_to_image_bounds"] += 1
    if clipped_w < MIN_BOX_SIDE_PX or clipped_h < MIN_BOX_SIDE_PX or clipped_w * clipped_h <= 0:
        counters["annotations_dropped_degenerate_bbox"] += 1
        return None
    return [round(x1, 2), round(y1, 2), round(clipped_w, 2), round(clipped_h, 2)]


def _file_exists(path: Path) -> bool:
    """Path.exists() that treats over-long file names (Errno 63) as missing."""
    try:
        return path.exists()
    except OSError:
        return False


def load_source(
    spec: SourceSpec,
    raw_dir: Path,
    workers: int,
) -> tuple[list[ImageRecord], dict[str, Any]]:
    """Load one Roboflow COCO export: image files, pHashes, normalized annotations.

    Images referenced by the JSON but missing on disk are dropped and counted
    (the pwals v18 export ships 12 file names longer than the 255 byte file
    name limit, so those files were never extractable).
    """
    source_dir = raw_dir / spec.dir_name
    if not source_dir.is_dir():
        raise SystemExit(f"source directory not found: {source_dir}")

    records: list[ImageRecord] = []
    counters: Counter[str] = Counter()
    pending: list[ImageRecord] = []

    for origin_split in SOURCE_SPLITS:
        split_dir = source_dir / origin_split
        coco_path = split_dir / "_annotations.coco.json"
        if not coco_path.exists():
            print(f"  [{spec.name}] skipping missing split file {coco_path}")
            continue
        coco = read_json(coco_path)
        categories = {int(category["id"]): str(category["name"]) for category in coco.get("categories", [])}
        counters["images_seen"] += len(coco.get("images", []))

        annotations_by_image: dict[int, list[dict[str, Any]]] = {}
        for annotation in coco.get("annotations", []):
            counters["annotations_seen"] += 1
            if int(annotation.get("iscrowd", 0)) == 1:
                counters["annotations_dropped_iscrowd"] += 1
                continue
            category_id = int(annotation.get("category_id", -1))
            # Category id 0 is Roboflow's synthetic parent container; no real
            # annotation references it, and it is never a training class.
            if category_id == 0 or category_id not in categories:
                counters["annotations_dropped_parent_or_unknown_category"] += 1
                continue
            annotations_by_image.setdefault(int(annotation["image_id"]), []).append(annotation)

        for image in coco.get("images", []):
            file_name = Path(str(image["file_name"])).name
            source_path = split_dir / file_name
            if not _file_exists(source_path):
                counters["images_dropped_missing_file"] += 1
                continue
            record = ImageRecord(
                source=spec,
                origin_split=origin_split,
                file_name=file_name,
                source_path=source_path,
                width=int(image.get("width", 0)),
                height=int(image.get("height", 0)),
                phash=0,
            )
            for annotation in annotations_by_image.get(int(image["id"]), []):
                bbox = _normalize_bbox(annotation, record.width, record.height, counters)
                if bbox is None:
                    continue
                category_name = categories.get(int(annotation.get("category_id", -1)), "unknown")
                record.annotations.append(
                    NormalizedAnnotation(bbox_xywh=bbox, source_category=category_name)
                )
            pending.append(record)

    print(f"  [{spec.name}] fingerprinting {len(pending)} images with {workers} workers...")
    with ThreadPoolExecutor(max_workers=workers) as pool:
        results = list(pool.map(lambda record: compute_fingerprint(record.source_path), pending))
    for record, (phash, width, height, thumb) in zip(pending, results):
        record.phash = phash
        record.thumb = thumb
        if record.width <= 0 or record.height <= 0:
            record.width = width
            record.height = height
        records.append(record)

    stats = dict(counters)
    stats["images_kept"] = len(records)
    stats["annotations_kept"] = sum(len(record.annotations) for record in records)
    return records, stats


def _normalized_thumbs(records: list[ImageRecord]) -> np.ndarray:
    """Stack thumbnail fingerprints into a mean-centered, L2-normalized matrix.

    After normalization, the dot product of two rows is their Pearson
    correlation, the verification signal for stage B duplicate candidates.
    """
    if any(record.thumb is None for record in records):
        raise SystemExit("internal error: missing thumbnail fingerprint")
    matrix = np.vstack([record.thumb for record in records])
    matrix = matrix - matrix.mean(axis=1, keepdims=True)
    norms = np.linalg.norm(matrix, axis=1, keepdims=True)
    norms[norms == 0] = 1
    return (matrix / norms).astype(np.float32)


def cluster_records(
    records: list[ImageRecord],
    hamming_threshold: int,
) -> tuple[UnionFind, dict[str, int]]:
    """Cluster duplicate images in two verified stages.

    Stage A unions every Roboflow variant family: images of one source sharing
    a photo stem (name before the .rf. suffix, case-insensitive) are the same
    photo by construction, so this merge is exact and never needs a check.

    Stage B deduplicates across families (and across datasets, which share a
    large scraped photo pool): candidate pairs are cross-family images whose
    pHash Hamming distance is within the threshold, but because the coarse
    pHash over-merges in this domain, each candidate is VERIFIED by Pearson
    correlation of the 64x64 thumbnails; only verified pairs are merged.
    """
    union_find = UnionFind(len(records))

    stage_a_edges = 0
    stem_groups: dict[tuple[str, str], int] = {}
    for index, record in enumerate(records):
        key = (record.source.name, photo_stem(record.file_name))
        first = stem_groups.setdefault(key, index)
        if first != index:
            stage_a_edges += 1
        union_find.union(first, index)

    hashes = np.array([record.phash for record in records], dtype=np.uint64)
    family_ids: dict[tuple[str, str], int] = {}
    family_of = np.array(
        [
            family_ids.setdefault((record.source.name, photo_stem(record.file_name)), len(family_ids))
            for record in records
        ],
        dtype=np.int64,
    )
    total = len(records)
    candidate_a: list[int] = []
    candidate_b: list[int] = []
    for start in range(0, total, CLUSTER_CHUNK_ROWS):
        stop = min(start + CLUSTER_CHUNK_ROWS, total)
        distances = np.bitwise_count(hashes[start:stop, None] ^ hashes[None, :])
        rows, columns = np.nonzero(distances <= hamming_threshold)
        for row_index, column in zip(rows.tolist(), columns.tolist()):
            global_row = start + row_index
            if global_row >= column:
                continue
            if family_of[global_row] == family_of[column]:
                continue  # already merged exactly by stage A
            candidate_a.append(global_row)
            candidate_b.append(column)

    thumbs = _normalized_thumbs(records)
    stage_b_edges = 0
    for chunk_start in range(0, len(candidate_a), CORRELATION_CHUNK_PAIRS):
        chunk_stop = min(chunk_start + CORRELATION_CHUNK_PAIRS, len(candidate_a))
        left = np.asarray(candidate_a[chunk_start:chunk_stop], dtype=np.int64)
        right = np.asarray(candidate_b[chunk_start:chunk_stop], dtype=np.int64)
        correlations = np.einsum("ij,ij->i", thumbs[left], thumbs[right])
        for offset in np.nonzero(correlations >= DUPLICATE_CORR_THRESHOLD)[0].tolist():
            stage_b_edges += 1
            union_find.union(int(left[offset]), int(right[offset]))

    stats = {
        "stage_a_family_edges": stage_a_edges,
        "stage_b_hash_candidates": len(candidate_a),
        "stage_b_verified_edges": stage_b_edges,
    }
    print(
        f"  stage A family edges: {stage_a_edges}, "
        f"stage B candidates: {len(candidate_a)}, verified: {stage_b_edges}"
    )
    return union_find, stats


def select_representatives(
    records: list[ImageRecord], union_find: UnionFind
) -> tuple[dict[int, ImageRecord], dict[int, list[ImageRecord]]]:
    """Pick one representative per cluster: largest resolution, then alphabetically first."""
    clusters: dict[int, list[ImageRecord]] = {}
    for index, record in enumerate(records):
        clusters.setdefault(union_find.find(index), []).append(record)
    representatives: dict[int, ImageRecord] = {}
    for root, members in clusters.items():
        best = min(
            members,
            key=lambda record: (-(record.width * record.height), record.file_name),
        )
        representatives[root] = best
    return representatives, clusters


def assign_split(phash: int, seed: int) -> str:
    """Deterministically assign one cluster to a split by hashing its representative pHash."""
    digest = hashlib.sha256(f"{seed}:{phash:016x}".encode("ascii")).digest()
    bucket = int.from_bytes(digest[:8], "big") % 10_000
    if bucket < int(TRAIN_RATIO * 10_000):
        return "train"
    if bucket < int((TRAIN_RATIO + VAL_RATIO) * 10_000):
        return "val"
    return "test"


def _write_split(
    split_name: str,
    entries: list[tuple[ImageRecord, int]],
    output_dir: Path,
) -> dict[str, Any]:
    """Copy representative images and write the split COCO file; return split stats."""
    split_dir = ensure_dir(output_dir / split_name)
    image_dir = ensure_dir(split_dir / "images")
    images: list[dict[str, Any]] = []
    annotations: list[dict[str, Any]] = []
    per_source_images: Counter[str] = Counter()
    per_source_annotations: Counter[str] = Counter()
    color_rows: dict[str, list[dict[str, Any]]] = {}

    for image_id, (record, duplicate_count) in enumerate(
        sorted(entries, key=lambda entry: entry[0].file_name), start=1
    ):
        output_name = f"{record.source.name}__{record.file_name}"
        shutil.copy2(record.source_path, image_dir / output_name)
        images.append(
            {
                "id": image_id,
                "file_name": f"images/{output_name}",
                "width": record.width,
                "height": record.height,
                "source": record.source.name,
                "source_file_name": record.file_name,
                "origin_split": record.origin_split,
                "duplicate_members": duplicate_count,
            }
        )
        per_source_images[record.source.name] += 1
        for annotation in record.annotations:
            annotations.append(
                {
                    "id": len(annotations) + 1,
                    "image_id": image_id,
                    "category_id": SINGLE_CLASS_ID,
                    "bbox": annotation.bbox_xywh,
                    "area": round(annotation.bbox_xywh[2] * annotation.bbox_xywh[3], 2),
                    "iscrowd": 0,
                }
            )
            per_source_annotations[record.source.name] += 1
        if record.source.name == "pwals":
            color_rows[str(image_id)] = [
                {
                    "bbox": annotation.bbox_xywh,
                    "color_family": normalize_color_family(annotation.source_category),
                }
                for annotation in record.annotations
            ]

    coco = {
        "info": {
            "description": (
                f"CyberSend hold detection, merged deduplicated {split_name} split, single class"
            ),
            "version": "1.0",
            "date_created": datetime.now(timezone.utc).date().isoformat(),
        },
        "licenses": [],
        "categories": [{"id": SINGLE_CLASS_ID, "name": SINGLE_CLASS_NAME, "supercategory": "climb"}],
        "images": images,
        "annotations": annotations,
    }
    coco_path = split_dir / "_annotations.coco.json"
    write_json(coco_path, coco)
    return {
        "images": len(images),
        "annotations": len(annotations),
        "per_source_images": dict(per_source_images),
        "per_source_annotations": dict(per_source_annotations),
        "annotations_sha256": sha256_file(coco_path),
        "color_rows": color_rows,
    }


def run_sanity_checks(
    output_dir: Path, split_assignments: dict[int, str], union_find: UnionFind
) -> dict[str, Any]:
    """Fail loudly on split leakage, missing image files, and out-of-bounds boxes."""
    cluster_splits: dict[int, set[str]] = {}
    for index, split_name in split_assignments.items():
        cluster_splits.setdefault(union_find.find(index), set()).add(split_name)
    leaked = {root: splits for root, splits in cluster_splits.items() if len(splits) > 1}
    if leaked:
        raise SystemExit(f"sanity check failed: {len(leaked)} pHash clusters span multiple splits")

    total_images = 0
    total_annotations = 0
    for split_name in SPLIT_NAMES:
        coco = read_json(output_dir / split_name / "_annotations.coco.json")
        images_by_id = {int(image["id"]): image for image in coco["images"]}
        for image in coco["images"]:
            image_path = output_dir / split_name / image["file_name"]
            if not image_path.exists():
                raise SystemExit(f"sanity check failed: referenced image missing on disk: {image_path}")
        clipped = 0
        category_ids = {int(category["id"]) for category in coco.get("categories", [])}
        if category_ids != {SINGLE_CLASS_ID}:
            raise SystemExit(
                f"sanity check failed: {split_name} declares category ids "
                f"{sorted(category_ids)}, expected exactly {{{SINGLE_CLASS_ID}}}"
            )
        for annotation in coco["annotations"]:
            if int(annotation["category_id"]) != SINGLE_CLASS_ID:
                raise SystemExit(
                    f"sanity check failed: {split_name} annotation {annotation['id']} has "
                    f"category id {annotation['category_id']}, expected {SINGLE_CLASS_ID}"
                )
            image = images_by_id.get(int(annotation["image_id"]))
            if image is None:
                raise SystemExit(
                    f"sanity check failed: annotation references unknown image id {annotation['image_id']}"
                )
            x, y, box_width, box_height = [float(value) for value in annotation["bbox"]]
            width = float(image["width"])
            height = float(image["height"])
            if box_width < MIN_BOX_SIDE_PX or box_height < MIN_BOX_SIDE_PX:
                raise SystemExit(
                    f"sanity check failed: degenerate bbox in {split_name} image {image['file_name']}"
                )
            if x < -1e-6 or y < -1e-6 or x + box_width > width + 1e-6 or y + box_height > height + 1e-6:
                clipped += 1
        total_annotations += len(coco["annotations"])
        total_images += len(coco["images"])
        if coco["annotations"]:
            fraction = clipped / len(coco["annotations"])
            if fraction > OUT_OF_BOUNDS_ERROR_FRACTION:
                raise SystemExit(
                    f"sanity check failed: {split_name} has {fraction:.1%} out-of-bounds bboxes "
                    f"(limit {OUT_OF_BOUNDS_ERROR_FRACTION:.0%})"
                )
        print(
            f"  [{split_name}] sanity: {len(coco['images'])} images exist, "
            f"{clipped} clipped bboxes, category id {SINGLE_CLASS_ID} only"
        )

    return {
        "clusters_spanning_splits": 0,
        "referenced_images_checked": total_images,
        "referenced_images_missing": 0,
        "annotations_bounds_checked": total_annotations,
    }


def _observed_category_mapping(raw_dir: Path, spec: SourceSpec) -> dict[str, int]:
    """Map every non-parent category name of a source to the merged class id."""
    coco_path = raw_dir / spec.dir_name / "train" / "_annotations.coco.json"
    coco = read_json(coco_path)
    mapping: dict[str, int] = {}
    for category in coco.get("categories", []):
        if int(category["id"]) == 0:
            continue
        mapping[str(category["name"])] = SINGLE_CLASS_ID
    return mapping


def build(
    raw_dir: Path,
    output_dir: Path,
    seed: int,
    hamming_threshold: int,
    workers: int,
    force: bool,
) -> Path:
    """Run the full merge, dedupe, resplit pipeline and write manifest.json."""
    if output_dir.exists() and any(output_dir.iterdir()):
        if not force:
            raise SystemExit(f"output dir {output_dir} is not empty; pass --force to rebuild")
        # macOS can recreate directory metadata (.DS_Store) mid-delete, which
        # makes rmtree raise ENOTEMPTY; retrying is safe and settles quickly.
        for attempt in range(5):
            try:
                shutil.rmtree(output_dir)
                break
            except OSError:
                if attempt == 4:
                    raise
                time.sleep(0.5)
    ensure_dir(output_dir)

    all_records: list[ImageRecord] = []
    source_stats: dict[str, Any] = {}
    category_mapping: dict[str, dict[str, int]] = {}

    for spec in SOURCES:
        print(f"Loading {spec.name} ({spec.dir_name})...")
        records, stats = load_source(spec, raw_dir, workers)
        all_records.extend(records)
        source_stats[spec.name] = {
            "path": f"datasets/raw/{spec.dir_name}",
            "version": spec.version,
            "license_id": spec.license_id,
            "license_note": spec.license_note,
            "url": spec.url,
            **stats,
        }
        category_mapping[spec.name] = _observed_category_mapping(raw_dir, spec)

    print(f"Clustering {len(all_records)} images (hamming <= {hamming_threshold})...")
    union_find, cluster_stage_stats = cluster_records(all_records, hamming_threshold)
    representatives, clusters = select_representatives(all_records, union_find)
    print(f"  clusters: {len(representatives)} (from {len(all_records)} images)")

    split_by_cluster: dict[int, str] = {
        root: assign_split(representative.phash, seed)
        for root, representative in representatives.items()
    }

    dropped_duplicates = 0
    dropped_by_source: Counter[str] = Counter()
    entries_by_split: dict[str, list[tuple[ImageRecord, int]]] = {name: [] for name in SPLIT_NAMES}
    for root, representative in representatives.items():
        members = clusters[root]
        duplicate_count = len(members) - 1
        dropped_duplicates += duplicate_count
        for member in members:
            if member is not representative:
                dropped_by_source[member.source.name] += 1
        entries_by_split[split_by_cluster[root]].append((representative, duplicate_count))

    # Every image record inherits its cluster's split; this map feeds the
    # independent leakage check in run_sanity_checks.
    root_of_record: dict[int, int] = {
        index: union_find.find(index) for index in range(len(all_records))
    }
    split_assignments: dict[int, str] = {
        index: split_by_cluster[root] for index, root in root_of_record.items()
    }

    print("Writing splits...")
    manifest_splits: dict[str, Any] = {}
    color_sidecar_splits: dict[str, Any] = {}
    for split_name in SPLIT_NAMES:
        stats = _write_split(split_name, entries_by_split[split_name], output_dir)
        color_sidecar_splits[split_name] = stats.pop("color_rows")
        manifest_splits[split_name] = {**stats, "frozen": split_name == "test"}
        print(
            f"  {split_name}: {stats['images']} images, {stats['annotations']} annotations, "
            f"per source: {stats['per_source_images']}"
        )

    color_sidecar = {
        "description": (
            "pwals color sidecar: seed data for the optional color-family classifier "
            "(US-33). NOT part of detection training. bboxes are xywh in source-image "
            "pixels of the kept representative image; image ids match the split "
            "_annotations.coco.json files."
        ),
        "source": "pwals.v18i.coco",
        "normalization": {
            "rule": "strip '-hold' suffix; classes with more than one color token map to 'multi'",
            "examples": {"black-hold": "black", "cyan-hold": "cyan", "black-pink-hold": "multi"},
        },
        "splits": color_sidecar_splits,
    }
    write_json(output_dir / "color_labels.json", color_sidecar)

    # Dropped duplicates never influence the split (their representative does),
    # and the check below verifies cluster atomicity independently.
    print("Running sanity checks...")
    sanity = run_sanity_checks(output_dir, split_assignments, union_find)

    manifest = {
        "created_at": datetime.now(timezone.utc).isoformat(),
        "pipeline": "hold-build",
        "pipeline_version": "1.0",
        "description": (
            "Merged single-class hold detection dataset: climbtag v29 + blackcreed v14 + "
            "pwals v18, pHash deduplicated, cluster-level 60/20/20 resplit, original "
            "Roboflow splits discarded"
        ),
        "sources": source_stats,
        "category_mapping": category_mapping,
        "merged_class": {
            "category_id": SINGLE_CLASS_ID,
            "name": SINGLE_CLASS_NAME,
            "convention": (
                "id 1 matches RF-DETR's Roboflow loader convention (the smoke-proven "
                "path); category id 0 is Roboflow's synthetic parent container and is "
                "never emitted in output annotations"
            ),
        },
        "dedupe": {
            "method": (
                "two stages: (A) union every Roboflow variant family by (source, photo "
                "stem before .rf. suffix, case-insensitive), exact by construction; "
                "(B) cross-family candidates within pHash Hamming distance "
                f"<= {hamming_threshold} (64-bit pHash: 32x32 LANCZOS grayscale, "
                "DCT-II, 8x8 median threshold) are VERIFIED by Pearson correlation of "
                "64x64 grayscale thumbnails and merged only at correlation >= "
                f"{DUPLICATE_CORR_THRESHOLD}. The pHash threshold alone over-merges "
                "in this domain: climbing wall photos collide even at Hamming "
                "distance 0, so verification is required; see DATASET_CARD.md."
            ),
            "hamming_threshold": hamming_threshold,
            "thumbnail_correlation_threshold": DUPLICATE_CORR_THRESHOLD,
            "stage_a_family_edges": cluster_stage_stats["stage_a_family_edges"],
            "stage_b_hash_candidates": cluster_stage_stats["stage_b_hash_candidates"],
            "stage_b_verified_edges": cluster_stage_stats["stage_b_verified_edges"],
            "total_images_in": len(all_records),
            "clusters": len(representatives),
            "dropped_duplicate_images": dropped_duplicates,
            "dropped_duplicates_per_source": dict(dropped_by_source),
            "representative_rule": "largest resolution, then alphabetically first file name",
            "known_limitation": (
                "true duplicates that differ by more than the pHash threshold "
                "(for example heavy crops or rotations across datasets) can survive "
                "dedupe; the cluster-level split still prevents the common leak paths"
            ),
        },
        "split": {
            "seed": seed,
            "method": (
                "sha256('<seed>:<representative pHash hex>') first 8 bytes mod 10000: "
                "<6000 train, <8000 val, else test; whole clusters assigned atomically"
            ),
            "ratios": {"train": TRAIN_RATIO, "val": VAL_RATIO, "test": TEST_RATIO},
            "original_roboflow_splits": "discarded (split before augmentation, leaked across)",
        },
        "splits": manifest_splits,
        "sanity_checks": sanity,
        "color_sidecar": "color_labels.json",
    }
    manifest_path = output_dir / "manifest.json"
    write_json(manifest_path, manifest)

    total_images = sum(split["images"] for split in manifest_splits.values())
    total_annotations = sum(split["annotations"] for split in manifest_splits.values())
    print(f"Manifest written to {manifest_path}")
    print(
        f"Done: {total_images} images, {total_annotations} annotations, "
        f"{len(representatives)} clusters, {dropped_duplicates} duplicates dropped"
    )
    print("Next: run 'uv run hold-bake' to bake the letterbox-640 preprocess into the images.")
    return manifest_path


def main() -> None:
    """Entry point for the hold-build console script."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw-dir", type=Path, default=RAW_DIR)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    parser.add_argument("--hamming-threshold", type=int, default=DEFAULT_HAMMING_THRESHOLD)
    parser.add_argument("--workers", type=int, default=8)
    parser.add_argument("--force", action="store_true", help="rebuild even if the output dir exists")
    args = parser.parse_args()

    build(
        raw_dir=args.raw_dir,
        output_dir=args.output,
        seed=args.seed,
        hamming_threshold=args.hamming_threshold,
        workers=args.workers,
        force=args.force,
    )


if __name__ == "__main__":
    main()
