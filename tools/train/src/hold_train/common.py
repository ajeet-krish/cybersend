"""Shared helpers for the CyberSend hold training pipeline."""

from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path
from typing import Any

# tools/train, resolved from src/hold_train/common.py.
PROJECT_ROOT = Path(__file__).resolve().parents[2]
DATASETS_DIR = PROJECT_ROOT / "datasets"
ARTIFACTS_DIR = PROJECT_ROOT / "artifacts"

SINGLE_CLASS_NAME = "hold"
# Single-class id used by every emitted COCO file. Id 1 (never 0) matches
# RF-DETR's Roboflow loader convention, which is the path proven by the smoke
# run; Roboflow itself uses id 0 only for a synthetic parent container that is
# never annotated.
SINGLE_CLASS_ID = 1


def js_round(value: float) -> int:
    """Round halves up for non-negative values, exactly like JavaScript Math.round.

    Python's round() uses banker's rounding (round(320.5) is 320), while the
    shared harness preprocess in tools/eval/src/preprocess.ts computes letterbox
    content sizes with Math.round (320.5 becomes 321). Every letterbox writer in
    this pipeline (hold-bake and hold-split) must use this rule so the harness
    letterbox stays a byte-consistent mirror of the training data.
    """
    return math.floor(value + 0.5)


def ensure_dir(path: Path) -> Path:
    """Create a directory (and parents) if needed and return it."""
    path.mkdir(parents=True, exist_ok=True)
    return path


def sha256_file(path: Path) -> str:
    """Return the hex sha256 digest of a file, streamed in chunks."""
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_json(path: Path, payload: Any) -> None:
    """Write JSON with stable formatting so diffs stay readable."""
    ensure_dir(path.parent)
    path.write_text(json.dumps(payload, indent=2, sort_keys=False) + "\n", encoding="utf-8")


def read_json(path: Path) -> Any:
    """Read a UTF-8 JSON file."""
    return json.loads(path.read_text(encoding="utf-8"))
