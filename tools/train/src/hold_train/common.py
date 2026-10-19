"""Shared helpers for the CyberSend hold training pipeline."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any

# tools/train, resolved from src/hold_train/common.py.
PROJECT_ROOT = Path(__file__).resolve().parents[2]
DATASETS_DIR = PROJECT_ROOT / "datasets"
ARTIFACTS_DIR = PROJECT_ROOT / "artifacts"

SINGLE_CLASS_NAME = "hold"


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
