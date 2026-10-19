"""Run the D1 baseline training (RF-DETR-Nano on the merged dataset) from a YAML config.

This is the D1 training entry point described in tools/train/README.md. It reads a
config file (configs/rf_detr_d1.yaml by default), materializes the Roboflow-style
"valid" split name RF-DETR expects (a "valid" symlink to the merged "val" folder),
then hands every parameter to RFDETRNano.train().

D1 runs take many hours and hundreds of megabytes of checkpoints. They require the
user's explicit approval before execution (see the WARNING in tools/train/README.md).
"""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import Any

import yaml

from .common import PROJECT_ROOT, ensure_dir

DEFAULT_CONFIG = PROJECT_ROOT / "configs" / "rf_detr_d1.yaml"


def load_config(config_path: Path) -> dict[str, Any]:
    """Read the D1 YAML config and validate the required keys."""
    payload = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise SystemExit(f"config {config_path} must be a YAML mapping")
    for key in ("dataset_dir", "output_dir", "model", "train"):
        if key not in payload:
            raise SystemExit(f"config {config_path} is missing required key '{key}'")
    return payload


def ensure_valid_alias(dataset_dir: Path) -> None:
    """RF-DETR's Roboflow-style loader reads valid/; the merged dataset uses val/.

    Creates datasets/merged/valid as a symlink to val when val exists and valid
    does not. On filesystems without symlink support, copy nothing and fail with
    instructions rather than silently duplicating data.
    """
    val_dir = dataset_dir / "val"
    valid_path = dataset_dir / "valid"
    if not val_dir.is_dir():
        raise SystemExit(f"expected {val_dir} to exist; run 'uv run hold-build' first")
    if valid_path.exists() or valid_path.is_symlink():
        return
    try:
        valid_path.symlink_to(val_dir, target_is_directory=True)
    except OSError as error:
        raise SystemExit(
            f"could not create the {valid_path} symlink ({error}). "
            f"Create it manually (for example: ln -s val {valid_path}) and rerun."
        ) from error
    print(f"created {valid_path} -> val (RF-DETR expects the Roboflow 'valid' name)")


def run(config_path: Path) -> None:
    """Construct RF-DETR-Nano from the config and start training."""
    config = load_config(config_path)
    dataset_dir = (PROJECT_ROOT / str(config["dataset_dir"])).resolve()
    output_dir = ensure_dir(PROJECT_ROOT / str(config["output_dir"]))
    ensure_valid_alias(dataset_dir)

    from rfdetr import RFDETRNano

    model_config = dict(config["model"])
    train_config = dict(config["train"])
    train_config["dataset_dir"] = str(dataset_dir)
    train_config["output_dir"] = str(output_dir)

    resolution = int(model_config.pop("resolution", 640))
    print(f"D1 baseline run: RF-DETR-Nano, resolution {resolution}")
    print(f"  config:    {config_path}")
    print(f"  dataset:   {dataset_dir}")
    print(f"  output:    {output_dir}")
    print(f"  train cfg: {sorted(train_config)}")

    model = RFDETRNano(resolution=resolution, **model_config)
    model.train(**train_config)
    print(f"D1 training complete; checkpoints are in {output_dir}")


def main() -> None:
    """Entry point for the hold-train-d1 console script."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    args = parser.parse_args()
    run(args.config)


if __name__ == "__main__":
    main()
