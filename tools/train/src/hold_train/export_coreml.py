"""Export a trained RF-DETR checkpoint to Core ML, optionally weight compressed.

This is the feasibility path, not a shipment path: docs/decisions.md records that
RF-DETR meets the accuracy thresholds but misses the false positive budget and
cannot meet the 15 MB int8 size budget at 28.9M parameters.

The conversion goes through rfdetr's own Core ML exporter (torch.export plus
coremltools), which rewrites deformable attention into a rank 5 path so the two
GridSample nodes of the decoder do not block conversion. The exporter pins
minimum deployment target to iOS16, which matches the app floor, and expects
ImageNet mean/std normalization on a 1x3x640x640 NCHW input, same as ONNX.

Weight compression uses coremltools palettization on top of a float16 package.
Palettization modes are KMEANS (needs scikit-learn), UNIFORM, UNIQUE, CUSTOM;
uniform is what the recorded 8 bit and 4 bit variants used. Compressed packages
do not pass the decision-space parity gate (docs/research.md), so treat them as
measurement artifacts, not deployment copies.

Run with the training environment, from tools/train:

    PYTHONPATH=src .venv/bin/python -m hold_train.export_coreml \
        --checkpoint artifacts/train_rf_detr_d1/checkpoint_best_total.pth \
        --output-dir artifacts/coreml_rfdetr_d1 --palettize-bits 8 4
"""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import Any

import coremltools as ct
from rfdetr import RFDETR

from .common import ARTIFACTS_DIR, write_json


def _package_size_mb(path: Path) -> float:
    """Total bytes of a .mlpackage directory in MB."""
    total = sum(f.stat().st_size for f in path.rglob("*") if f.is_file())
    return round(total / (1024 * 1024), 1)


def _palettize(source: Path, destination: Path, nbits: int) -> Path:
    """Compress weights to nbits with uniform palettization and save."""
    from coremltools.optimize.coreml import (
        OptimizationConfig,
        OpPalettizerConfig,
        palettize_weights,
    )

    base = ct.models.MLModel(str(source))
    config = OptimizationConfig(global_config=OpPalettizerConfig(nbits=nbits, mode="uniform"))
    palettize_weights(base, config).save(str(destination))
    return destination


def export(
    checkpoint: Path,
    output_dir: Path,
    precision: str = "float32",
    palettize_bits: list[int] | None = None,
) -> dict[str, Any]:
    """Export the checkpoint, then optionally compress the float16 package."""
    output_dir.mkdir(parents=True, exist_ok=True)
    model = RFDETR.from_checkpoint(str(checkpoint))
    exported = model.export(
        output_dir=str(output_dir),
        format="coreml",
        coreml_precision=precision,
        verbose=False,
    )

    packages: list[dict[str, Any]] = [
        {"variant": precision, "path": str(exported), "size_mb": _package_size_mb(Path(exported))}
    ]

    if palettize_bits:
        base = Path(exported)
        if "_fp16" not in base.name:
            base = Path(model.export(
                output_dir=str(output_dir), format="coreml", coreml_precision="float16", verbose=False
            ))
            packages.append(
                {"variant": "float16", "path": str(base), "size_mb": _package_size_mb(base)}
            )
        for nbits in palettize_bits:
            destination = base.with_name(base.name.replace("_fp16", f"_int{nbits}"))
            _palettize(base, destination, nbits)
            packages.append(
                {
                    "variant": f"int{nbits}",
                    "path": str(destination),
                    "size_mb": _package_size_mb(destination),
                }
            )

    return {"checkpoint": str(checkpoint), "packages": packages}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, default=ARTIFACTS_DIR / "coreml_rfdetr_d1")
    parser.add_argument("--precision", default="float32", choices=["float32", "float16"])
    parser.add_argument(
        "--palettize-bits",
        type=int,
        nargs="*",
        default=None,
        help="weight palettization widths to also produce (for example 8 4)",
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        default=None,
        help="where to write the export manifest JSON",
    )
    args = parser.parse_args()

    if not args.checkpoint.exists():
        raise SystemExit(f"checkpoint not found: {args.checkpoint}")

    summary = export(args.checkpoint, args.output_dir, args.precision, args.palettize_bits)
    manifest = args.manifest or (args.output_dir / "coreml_export.json")
    write_json(manifest, summary)

    print(f"checkpoint: {args.checkpoint}")
    for package in summary["packages"]:
        print(f"  {package['variant']:8s} {package['size_mb']:7.1f} MB  {package['path']}")
    print(f"manifest written to {manifest}")
    print("next: parity_coreml.py against the canonical ONNX graph before any use")


if __name__ == "__main__":
    main()
