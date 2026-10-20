"""Export a trained RF-DETR checkpoint to ONNX and write the artifact manifest.

Produces:
    artifacts/holds_detector_smoke.onnx   (opset 17, input 1x3x640x640)
    artifacts/manifest.json               (framework, licenses, input/output spec, training config)

The artifact id, version, and purpose are CLI parameters (--id, --version,
--purpose) so the same script exports the smoke spike and the D1 baseline;
dataset provenance is read from <dataset-dir>/manifest.json (datasets/merged
for D1, written by hold-build and updated by hold-bake).

Export contract (verified with onnxruntime after export):
    input  "input" : float32 [1, 3, 640, 640], NCHW RGB, ImageNet normalized,
                     image letterboxed to 640x640 with pad value 114 (centered)
    output "dets"  : float32 [1, num_queries, 4], normalized cxcywh in 0..1 of the
                     640x640 letterboxed frame
    output "labels": float32 [1, num_queries, num_classes + 1], logits where the
                     trailing channel is the no-object class (rfdetr models/lwdetr.py
                     heads are num_classes + 1 wide). Channel 0 is the "hold" score;
                     independent sigmoid, no softmax.
"""

from __future__ import annotations

import argparse
import importlib.metadata
import platform
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import numpy as np
import onnxruntime as ort
from rfdetr import RFDETR

from .common import ARTIFACTS_DIR, DATASETS_DIR, PROJECT_ROOT, read_json, sha256_file, write_json

DEFAULT_OPSET = 17
DEFAULT_RESOLUTION = 640
MODEL_LICENSE_ID = "Apache-2.0"


def _inspect_onnx(onnx_path: Path) -> dict[str, Any]:
    """Read input/output names, shapes, and opset from the exported ONNX file."""
    session = ort.InferenceSession(str(onnx_path), providers=["CPUExecutionProvider"])
    inputs = [{"name": i.name, "shape": [int(d) if isinstance(d, int) else d for d in i.shape], "dtype": i.type}
              for i in session.get_inputs()]
    outputs = [{"name": o.name, "shape": [int(d) if isinstance(d, int) else d for d in o.shape], "dtype": o.type}
               for o in session.get_outputs()]
    return {"inputs": inputs, "outputs": outputs}


def _training_summary(training_config_path: Path, fallback: dict[str, Any]) -> dict[str, Any]:
    """Merge the trainer-written config with a small fallback summary."""
    if not training_config_path.exists():
        return fallback
    written = read_json(training_config_path)
    train_config = written.get("train_config", {})
    model_config = written.get("model_config", {})
    return {
        **fallback,
        "config_file": str(training_config_path),
        "epochs": train_config.get("epochs"),
        "batch_size": train_config.get("batch_size"),
        "lr": train_config.get("lr"),
        "lr_encoder": train_config.get("lr_encoder"),
        "seed": train_config.get("seed"),
        "weight_decay": train_config.get("weight_decay"),
        "optimizer": train_config.get("optimizer"),
        "lr_scheduler": train_config.get("lr_scheduler"),
        "num_workers": train_config.get("num_workers"),
        "resolution": model_config.get("resolution", fallback.get("resolution")),
        "num_classes": written.get("num_classes"),
        "class_names": written.get("class_names"),
        "pretrained_checkpoint": model_config.get("pretrain_weights"),
        "encoder": model_config.get("encoder"),
    }


def export_artifact(
    checkpoint_path: Path,
    onnx_path: Path,
    manifest_path: Path,
    dataset_dir: Path,
    opset: int,
    resolution: int,
    training_config: dict[str, Any],
    artifact_id: str,
    artifact_version: str,
    artifact_purpose: str,
) -> None:
    """Export checkpoint to ONNX and write manifest.json next to it."""
    print(f"Loading checkpoint {checkpoint_path}")
    model = RFDETR.from_checkpoint(str(checkpoint_path))

    export_dir = onnx_path.parent
    export_dir.mkdir(parents=True, exist_ok=True)
    print(f"Exporting ONNX (opset {opset}, float32) to {export_dir}")
    exported = Path(
        model.export(
            output_dir=str(export_dir),
            format="onnx",
            opset_version=opset,
            verbose=False,
            fp16=False,
        )
    )
    if exported != onnx_path:
        exported.replace(onnx_path)

    io_spec = _inspect_onnx(onnx_path)
    inner = model.model.model
    num_params = sum(int(p.numel()) for p in inner.parameters())

    dataset_manifest_path = dataset_dir / "manifest.json"
    dataset_license_path = dataset_dir / "LICENSE"
    manifest: dict[str, Any] = {
        "id": artifact_id,
        "version": artifact_version,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "purpose": artifact_purpose,
        "license": {
            "model_license_id": MODEL_LICENSE_ID,
            "framework": "RF-DETR (roboflow/rf-detr)",
            "framework_license_id": MODEL_LICENSE_ID,
            "framework_version": importlib.metadata.version("rfdetr"),
            "torch_version": importlib.metadata.version("torch"),
        },
        "dataset": {
            "name": dataset_dir.name,
            "license_file": str(dataset_license_path.relative_to(PROJECT_ROOT)) if dataset_license_path.exists() else None,
            "license_summary": _dataset_license_summary(dataset_dir),
            "dataset_manifest": str(dataset_manifest_path.relative_to(PROJECT_ROOT)) if dataset_manifest_path.exists() else None,
            "dataset_manifest_sha256": sha256_file(dataset_manifest_path) if dataset_manifest_path.exists() else None,
        },
        "model": {
            "architecture": "RF-DETR-Nano",
            "num_parameters": num_params,
            "file_bytes": onnx_path.stat().st_size,
            "sha256": sha256_file(onnx_path),
            "onnx_opset": opset,
        },
        "checkpoint": {
            "source_file": str(checkpoint_path),
            "file_bytes": checkpoint_path.stat().st_size,
            "sha256": sha256_file(checkpoint_path),
            "epochs_configured": training_config.get("epochs"),
            "selected_by": "best validation mAP across epochs (RF-DETR best checkpoint in the training output directory)",
            "pretrained_init": training_config.get("pretrained_checkpoint"),
        },
        "input_spec": {
            "name": io_spec["inputs"][0]["name"],
            "shape": "1x3x640x640",
            "layout": "NCHW",
            "color_space": "RGB",
            "dtype": "float32",
            "letterbox": {"size": resolution, "pad_value": 114, "alignment": "centered", "resampling": "BICUBIC"},
            "normalization": {
                "scale": "value / 255.0",
                "mean": [0.485, 0.456, 0.406],
                "std": [0.229, 0.224, 0.225],
            },
            "shared_implementation": "tools/eval/src/preprocess.ts",
        },
        "output_spec": {
            "dets": {
                "description": "normalized cxcywh boxes in the 640x640 letterboxed frame",
                "observed_shape": io_spec["outputs"][0]["shape"],
            },
            "labels": {
                "description": (
                    "logits with num_classes + 1 channels; channel 0..num_classes-1 are the class "
                    "logits (channel 0 = hold) and the trailing channel is no-object. "
                    "Independent sigmoid, no softmax."
                ),
                "observed_shape": io_spec["outputs"][1]["shape"],
                "num_classes_configured": training_config.get("num_classes"),
            },
        },
        "training_config": training_config,
        "build_host": {"platform": platform.platform(), "machine": platform.machine()},
    }
    write_json(manifest_path, manifest)
    print(f"ONNX artifact: {onnx_path} ({manifest['model']['file_bytes']} bytes)")
    print(f"sha256: {manifest['model']['sha256']}")
    print(f"Manifest written to {manifest_path}")


def _dataset_license_summary(dataset_dir: Path) -> str:
    """Summarize the dataset license recorded next to the data."""
    notice_path = dataset_dir / "NOTICE.json"
    if notice_path.exists():
        notice = read_json(notice_path)
        return f"{notice.get('declared_license', 'unknown')} ({notice.get('usage', 'see NOTICE.json')})"
    return "see LICENSE file next to the dataset"


def _resolve_checkpoint(explicit: Path | None) -> Path:
    """Pick the best available RF-DETR checkpoint in the training output directory."""
    if explicit is not None:
        return explicit
    output_dir = ARTIFACTS_DIR / "train_smoke"
    # RF-DETR 1.11.x with EMA enabled writes checkpoint_best_ema.pth; older naming is
    # checkpoint_best_total.pth. Prefer total, then EMA.
    for candidate in ("checkpoint_best_total.pth", "checkpoint_best_ema.pth"):
        path = output_dir / candidate
        if path.exists():
            return path
    return output_dir / "checkpoint_best_ema.pth"


def main() -> None:
    """Entry point for the hold-export console script."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--checkpoint",
        type=Path,
        default=None,
        help="defaults to the best checkpoint under artifacts/train_smoke",
    )
    parser.add_argument("--output", type=Path, default=ARTIFACTS_DIR / "holds_detector_smoke.onnx")
    parser.add_argument("--manifest", type=Path, default=ARTIFACTS_DIR / "manifest.json")
    parser.add_argument("--dataset-dir", type=Path, default=DATASETS_DIR / "merged")
    parser.add_argument("--opset", type=int, default=DEFAULT_OPSET)
    parser.add_argument("--resolution", type=int, default=DEFAULT_RESOLUTION)
    parser.add_argument(
        "--id",
        dest="artifact_id",
        default="holds_detector_smoke",
        help="artifact id recorded in the export manifest (for example holds_detector_d1)",
    )
    parser.add_argument(
        "--version",
        dest="artifact_version",
        default="0.1.0",
        help="artifact version recorded in the export manifest",
    )
    parser.add_argument(
        "--purpose",
        dest="artifact_purpose",
        default="Phase 0 training spike smoke test, not a shippable model",
        help="human-readable purpose recorded in the export manifest",
    )
    args = parser.parse_args()

    checkpoint_path = _resolve_checkpoint(args.checkpoint)
    if not checkpoint_path.exists():
        raise SystemExit(f"Checkpoint not found: {checkpoint_path}. Run hold-train-smoke first.")
    print(f"Exporting from checkpoint: {checkpoint_path}")
    print(f"Artifact id: {args.artifact_id} ({args.artifact_version})")

    training_config_path = checkpoint_path.parent / "training_config.json"
    export_artifact(
        checkpoint_path=checkpoint_path,
        onnx_path=args.output,
        manifest_path=args.manifest,
        dataset_dir=args.dataset_dir,
        opset=args.opset,
        resolution=args.resolution,
        artifact_id=args.artifact_id,
        artifact_version=args.artifact_version,
        artifact_purpose=args.artifact_purpose,
        training_config=_training_summary(
            training_config_path,
            fallback={
                "script": "hold-train-smoke",
                "variant": "RF-DETR-Nano",
                "resolution": args.resolution,
                "note": "smoke run, see README.md for the full training recipe",
            },
        ),
    )


if __name__ == "__main__":
    main()
