"""Export a trained RF-DETR checkpoint to Core ML, optionally weight compressed.

This is the feasibility path, not a shipment path: docs/decisions.md records that
RF-DETR meets the accuracy thresholds but misses the false positive budget and
cannot meet the 15 MB int8 size budget at 28.9M parameters.

The conversion goes through rfdetr's own Core ML exporter (torch.export plus
coremltools), which rewrites deformable attention into a rank 5 path so the two
GridSample nodes of the decoder do not block conversion. The exporter pins
minimum deployment target to iOS16, which matches the app floor, and expects
ImageNet mean/std normalization on a 1x3x640x640 NCHW input, same as ONNX.

Weight compression has two independent paths on top of a float16 package:

  palettize  coremltools palettization, a shared lookup table per weight tensor.
             Modes are KMEANS (needs scikit-learn), UNIFORM, UNIQUE, CUSTOM;
             uniform is what the recorded 8 bit and 4 bit variants used.
  linear     coremltools linear_quantize_weights, per-channel symmetric
             quantization with a scale and zero point per output channel. This
             keeps far more precision than palettization at the same bit width,
             because a lookup table shared across a whole tensor cannot track
             per-channel weight ranges.

Both write a float16 package with quantized weights; activations stay float16.
Compressed packages must still pass the decision-space parity gate before any
use (parity_coreml.py), and none of the palettized variants do (docs/research.md).

Use --from-package to compress an existing package without re-running the
RF-DETR export, which is the fast path when only the compression changes:

    PYTHONPATH=src .venv/bin/python -m hold_train.export_coreml \
        --from-package artifacts/coreml_rfdetr_d1/rfdetr-nano_fp16.mlpackage \
        --output-dir artifacts/coreml_rfdetr_d1 --quantize-bits 8 4

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


def _quantize(source: Path, destination: Path, nbits: int) -> Path:
    """Compress weights to nbits with per-channel symmetric linear quantization."""
    from coremltools.optimize.coreml import (
        OptimizationConfig,
        OpLinearQuantizerConfig,
        linear_quantize_weights,
    )

    base = ct.models.MLModel(str(source))
    config = OptimizationConfig(
        global_config=OpLinearQuantizerConfig(
            mode="linear_symmetric",
            dtype=f"int{nbits}",
            granularity="per_channel",
        )
    )
    linear_quantize_weights(base, config).save(str(destination))
    return destination


def _palettize(
    source: Path,
    destination: Path,
    nbits: int,
    mode: str = "uniform",
    granularity: str = "per_tensor",
    group_size: int = 32,
    per_channel_scale: bool = False,
) -> Path:
    """Compress weights to nbits with palettization and save.

    KMEANS builds the lookup table from the weight distribution, which tracks
    per-channel ranges far better than a uniform grid. Grouped-channel
    granularity plus a per-channel scale is what makes 4-bit viable on
    transformer weights.
    """
    from coremltools.optimize.coreml import (
        OptimizationConfig,
        OpPalettizerConfig,
        palettize_weights,
    )

    base = ct.models.MLModel(str(source))
    options: dict[str, Any] = {"nbits": nbits, "mode": mode}
    if granularity != "per_tensor":
        options["granularity"] = granularity
        options["group_size"] = group_size
    if per_channel_scale:
        options["enable_per_channel_scale"] = True
    config = OptimizationConfig(global_config=OpPalettizerConfig(**options))
    palettize_weights(base, config).save(str(destination))
    return destination


def export(
    checkpoint: Path | None,
    output_dir: Path,
    precision: str = "float32",
    palettize_bits: list[int] | None = None,
    quantize_bits: list[int] | None = None,
    from_package: Path | None = None,
    palettize_mode: str = "uniform",
    palettize_granularity: str = "per_tensor",
    palettize_group_size: int = 32,
    palettize_per_channel_scale: bool = False,
) -> dict[str, Any]:
    """Export the checkpoint (or reuse a package), then optionally compress."""
    output_dir.mkdir(parents=True, exist_ok=True)

    if from_package is not None:
        exported = from_package
        packages: list[dict[str, Any]] = [
            {
                "variant": "source",
                "path": str(exported),
                "size_mb": _package_size_mb(exported),
            }
        ]
        base = exported
    else:
        if checkpoint is None:
            raise SystemExit("either --checkpoint or --from-package is required")
        model = RFDETR.from_checkpoint(str(checkpoint))
        exported = Path(
            model.export(
                output_dir=str(output_dir),
                format="coreml",
                coreml_precision=precision,
                verbose=False,
            )
        )
        packages = [
            {"variant": precision, "path": str(exported), "size_mb": _package_size_mb(exported)}
        ]
        base = exported
        if (palettize_bits or quantize_bits) and "_fp16" not in base.name:
            base = Path(
                model.export(
                    output_dir=str(output_dir),
                    format="coreml",
                    coreml_precision="float16",
                    verbose=False,
                )
            )
            packages.append(
                {"variant": "float16", "path": str(base), "size_mb": _package_size_mb(base)}
            )

    for nbits in palettize_bits or []:
        suffix = f"_int{nbits}" if palettize_mode == "uniform" and palettize_granularity == "per_tensor" else f"_int{nbits}{palettize_mode}{palettize_granularity.replace('per_', '')}"
        destination = base.with_name(base.name.replace("_fp16", suffix))
        _palettize(
            base,
            destination,
            nbits,
            palettize_mode,
            palettize_granularity,
            palettize_group_size,
            palettize_per_channel_scale,
        )
        packages.append(
            {
                "variant": suffix.lstrip("_"),
                "path": str(destination),
                "size_mb": _package_size_mb(destination),
            }
        )

    for nbits in quantize_bits or []:
        destination = base.with_name(base.name.replace("_fp16", f"_lin{nbits}"))
        _quantize(base, destination, nbits)
        packages.append(
            {
                "variant": f"lin{nbits}",
                "path": str(destination),
                "size_mb": _package_size_mb(destination),
            }
        )

    return {"checkpoint": str(checkpoint) if checkpoint else None, "packages": packages}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", type=Path, default=None)
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
        "--palettize-mode",
        default="uniform",
        choices=["uniform", "kmeans", "unique"],
        help="palettization lookup table construction (uniform by default)",
    )
    parser.add_argument(
        "--palettize-granularity",
        default="per_tensor",
        choices=["per_tensor", "per_grouped_channel"],
        help="palettization granularity (per_grouped_channel with a group size is "
        "what makes 4-bit viable on transformer weights)",
    )
    parser.add_argument("--palettize-group-size", type=int, default=32)
    parser.add_argument(
        "--palettize-per-channel-scale",
        action="store_true",
        help="enable a per-channel scale on top of the palettized weights",
    )
    parser.add_argument(
        "--quantize-bits",
        type=int,
        nargs="*",
        default=None,
        help="per-channel linear quantization widths to also produce (for example 8 4)",
    )
    parser.add_argument(
        "--from-package",
        type=Path,
        default=None,
        help="compress this existing .mlpackage instead of exporting the checkpoint",
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        default=None,
        help="where to write the export manifest JSON",
    )
    args = parser.parse_args()

    if args.checkpoint is None and args.from_package is None:
        raise SystemExit("either --checkpoint or --from-package is required")
    if args.checkpoint is not None and not args.checkpoint.exists():
        raise SystemExit(f"checkpoint not found: {args.checkpoint}")
    if args.from_package is not None and not args.from_package.exists():
        raise SystemExit(f"package not found: {args.from_package}")

    summary = export(
        args.checkpoint,
        args.output_dir,
        args.precision,
        args.palettize_bits,
        args.quantize_bits,
        args.from_package,
        args.palettize_mode,
        args.palettize_granularity,
        args.palettize_group_size,
        args.palettize_per_channel_scale,
    )
    manifest = args.manifest or (args.output_dir / "coreml_export.json")
    write_json(manifest, summary)

    print(f"checkpoint: {args.checkpoint or args.from_package}")
    for package in summary["packages"]:
        print(f"  {package['variant']:8s} {package['size_mb']:7.1f} MB  {package['path']}")
    print(f"manifest written to {manifest}")
    print("next: parity_coreml.py against the canonical ONNX graph before any use")


if __name__ == "__main__":
    main()
