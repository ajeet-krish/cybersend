"""Smoke-train RF-DETR-Nano on the prepared hold dataset (a few epochs only).

Purpose: prove the Apache-2.0 pipeline end to end. Loss must decrease and the run must
produce a checkpoint that hold-export can turn into ONNX. This is NOT the Phase 4
quality run; the full training recipe lives in tools/train/README.md.

RF-DETR-Nano is chosen for the spike because `pip install rfdetr[train]` works cleanly
on Apple Silicon (no source build, MPS available via PyTorch Lightning accelerator).
"""

from __future__ import annotations

import argparse
from pathlib import Path

from rfdetr import RFDETRNano

from .common import ARTIFACTS_DIR, DATASETS_DIR

DEFAULT_SEED = 20261019
DEFAULT_RESOLUTION = 640
DEFAULT_EPOCHS = 3
DEFAULT_BATCH_SIZE = 4


def train_smoke(
    dataset_dir: Path,
    output_dir: Path,
    epochs: int,
    batch_size: int,
    resolution: int,
    seed: int,
    device: str,
    lr: float,
) -> None:
    """Fine-tune RF-DETR-Nano for a few epochs on the prepared letterboxed dataset."""
    prepared = dataset_dir / "prepared"
    if not (prepared / "train" / "_annotations.coco.json").exists():
        raise SystemExit(
            f"Prepared dataset not found at {prepared}. Run hold-convert and hold-split first."
        )

    print(f"Training RF-DETR-Nano: epochs={epochs} batch_size={batch_size} "
          f"resolution={resolution} seed={seed} device={device} lr={lr}")
    print(f"dataset_dir={prepared}")
    print(f"output_dir={output_dir}")

    model = RFDETRNano(resolution=resolution)
    model.train(
        dataset_dir=str(prepared),
        epochs=epochs,
        batch_size=batch_size,
        seed=seed,
        device=device,
        lr=lr,
        output_dir=str(output_dir),
        num_workers=2,
    )
    print("Training complete.")


def main() -> None:
    """Entry point for the hold-train-smoke console script."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-dir", type=Path, default=DATASETS_DIR / "climbinst_smoke")
    parser.add_argument("--output-dir", type=Path, default=ARTIFACTS_DIR / "train_smoke")
    parser.add_argument("--epochs", type=int, default=DEFAULT_EPOCHS)
    parser.add_argument("--batch-size", type=int, default=DEFAULT_BATCH_SIZE)
    parser.add_argument("--resolution", type=int, default=DEFAULT_RESOLUTION)
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    parser.add_argument("--device", type=str, default="mps", choices=("mps", "cpu", "cuda"))
    parser.add_argument("--lr", type=float, default=1e-4)
    args = parser.parse_args()

    train_smoke(
        dataset_dir=args.dataset_dir,
        output_dir=args.output_dir,
        epochs=args.epochs,
        batch_size=args.batch_size,
        resolution=args.resolution,
        seed=args.seed,
        device=args.device,
        lr=args.lr,
    )


if __name__ == "__main__":
    main()
