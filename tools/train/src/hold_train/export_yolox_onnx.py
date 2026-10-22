"""Export the trained YOLOX-Nano D1 checkpoint to ONNX with in-graph decode.

Produces:
    artifacts/holds_detector_yolox_d1.onnx   (opset 17, input 1x3x640x640)
    artifacts/manifest_yolox_d1.json         (framework, licenses, input/output spec)

The Megvii tool (yolox.tools.export_onnx) cannot run on the pinned torch 2.14:
it calls the removed private helper torch.onnx._export. This module is the
committed replacement, using the public torch.onnx.export with the legacy
tracer (dynamo=False), which is the path the YOLOX 0.3.0 graph is proven
against. Run it with the isolated YOLOX environment, from tools/train:

    PYTHONPATH=src .venv-yolox/bin/python -m hold_train.export_yolox_onnx

Export contract (verified with onnxruntime after export):
    input  "images": float32 [1, 3, 640, 640], NCHW RGB in 0..255 with NO
                     ImageNet normalization. This differs from the RF-DETR
                     export and from the shared harness contract in
                     tools/eval/src/preprocess.ts (which applies ImageNet
                     stats): YOLOX was trained on 0..255 RGB (cv2 reads BGR,
                     the YOLOX preproc flips to RGB; /255 is never applied).
                     Any YOLOX eval path therefore needs its own preprocess
                     mode rather than the RF-DETR ImageNet normalization.
    output "output" : float32 [1, num_anchors, 4 + 1 + num_classes], decoded
                     in-graph (head.decode_in_inference = True): cx cy w h in
                     pixels of the 640x640 letterboxed frame, then objectness
                     and class score, both after sigmoid. No NMS inside the
                     graph; the consumer applies NMS.
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
import torch
from torch import nn

from .common import ARTIFACTS_DIR, PROJECT_ROOT, ensure_dir, sha256_file, write_json

DEFAULT_OPSET = 17
DEFAULT_RESOLUTION = 640
MODEL_LICENSE_ID = "Apache-2.0"
FRAMEWORK_NAME = "YOLOX 0.3.0 (Megvii, Apache-2.0; MPS patch tools/train/patches/yolox-0.3.0-mps.patch)"


def _inspect_onnx(onnx_path: Path) -> dict[str, Any]:
    """Read input/output names, shapes, and opset from the exported ONNX file."""
    session = ort.InferenceSession(str(onnx_path), providers=["CPUExecutionProvider"])
    inputs = [{"name": i.name, "shape": [int(d) if isinstance(d, int) else d for d in i.shape], "dtype": i.type}
              for i in session.get_inputs()]
    outputs = [{"name": o.name, "shape": [int(d) if isinstance(d, int) else d for d in o.shape], "dtype": o.type}
               for o in session.get_outputs()]
    return {"inputs": inputs, "outputs": outputs}


def _load_model(exp_file: Path, checkpoint_path: Path) -> tuple[nn.Module, dict[str, Any]]:
    """Build the depthwise YOLOX-Nano from the exp file and load the trained weights."""
    from yolox.exp import get_exp
    from yolox.models.network_blocks import SiLU
    from yolox.utils import replace_module

    exp = get_exp(str(exp_file))
    model = exp.get_model()
    # torch >= 2.6 defaults torch.load to weights_only=True; YOLOX checkpoints
    # carry a numpy best_map value, so the trusted local checkpoint is loaded
    # with weights_only=False (same handling as the documented resume path).
    ckpt = torch.load(checkpoint_path, map_location="cpu", weights_only=False)
    state_dict = ckpt["model"] if isinstance(ckpt, dict) and "model" in ckpt else ckpt
    missing, unexpected = model.load_state_dict(state_dict, strict=True), None
    del missing
    model = replace_module(model, nn.SiLU, SiLU)
    model.head.decode_in_inference = True
    model.eval()
    metadata = {
        "start_epoch": ckpt.get("start_epoch") if isinstance(ckpt, dict) else None,
        "best_map": float(ckpt["best_map"]) if isinstance(ckpt, dict) and "best_map" in ckpt else None,
        "depth": exp.depth,
        "width": exp.width,
        "num_classes": exp.num_classes,
        "test_size": list(exp.test_size),
    }
    return model, metadata


def export_artifact(
    exp_file: Path,
    checkpoint_path: Path,
    onnx_path: Path,
    manifest_path: Path,
    opset: int,
    resolution: int,
    artifact_id: str,
    artifact_version: str,
    artifact_purpose: str,
) -> None:
    """Export the YOLOX checkpoint to ONNX (with decode) and write a provenance manifest."""
    print(f"Loading checkpoint {checkpoint_path}")
    model, metadata = _load_model(exp_file, checkpoint_path)

    ensure_dir(onnx_path.parent)
    dummy_input = torch.zeros(1, 3, resolution, resolution)
    print(f"Exporting ONNX (opset {opset}, float32, legacy tracer) to {onnx_path}")
    torch.onnx.export(
        model,
        dummy_input,
        str(onnx_path),
        input_names=["images"],
        output_names=["output"],
        opset_version=opset,
        do_constant_folding=True,
        dynamo=False,
    )

    try:
        import onnx

        from onnxsim import simplify

        onnx_model = onnx.load(str(onnx_path))
        simplified, check_ok = simplify(onnx_model, dynamic_input_shape=False)
        if check_ok:
            onnx.save(simplified, str(onnx_path))
            print("Simplified ONNX graph with onnxsim.")
        else:
            print("onnxsim validation failed; keeping the unsimplified graph.")
    except ImportError:
        print("onnxsim not installed; keeping the unsimplified graph.")

    io_spec = _inspect_onnx(onnx_path)
    num_params = sum(int(p.numel()) for p in model.parameters())
    num_anchors = int(io_spec["outputs"][0]["shape"][1])

    manifest: dict[str, Any] = {
        "id": artifact_id,
        "version": artifact_version,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "purpose": artifact_purpose,
        "license": {
            "model_license_id": MODEL_LICENSE_ID,
            "framework": FRAMEWORK_NAME,
            "framework_license_id": MODEL_LICENSE_ID,
            "framework_version": importlib.metadata.version("yolox"),
            "torch_version": torch.__version__,
        },
        "dataset": {
            "name": "merged",
            "note": "merged D1 dataset (train 1804, val 591, frozen test 582); see datasets/merged/manifest.json",
        },
        "model": {
            "architecture": "YOLOX-Nano (depthwise separable convs, depth 0.33, width 0.25)",
            "num_parameters": num_params,
            "file_bytes": onnx_path.stat().st_size,
            "sha256": sha256_file(onnx_path),
            "onnx_opset": opset,
            "decode_in_graph": True,
            "num_anchors": num_anchors,
        },
        "checkpoint": {
            "source_file": str(checkpoint_path),
            "file_bytes": checkpoint_path.stat().st_size,
            "sha256": sha256_file(checkpoint_path),
            "start_epoch": metadata["start_epoch"],
            "best_map": metadata["best_map"],
            "selected_by": "best validation mAP 50:95 across epochs (YOLOX best_ckpt.pth)",
        },
        "input_spec": {
            "name": io_spec["inputs"][0]["name"],
            "shape": f"1x3x{resolution}x{resolution}",
            "layout": "NCHW",
            "color_space": "RGB",
            "dtype": "float32",
            "value_range": "0..255",
            "letterbox": {"size": resolution, "pad_value": 114, "alignment": "centered", "resampling": "BICUBIC"},
            "normalization": {
                "scale": "none (raw 0..255 RGB, as trained by the YOLOX preproc)",
                "note": (
                    "differs from the RF-DETR contract and tools/eval/src/preprocess.ts, which apply "
                    "ImageNet mean/std; a YOLOX eval path needs its own preprocess mode"
                ),
            },
        },
        "output_spec": {
            "output": {
                "description": (
                    "decoded predictions: cx cy w h in pixels of the 640x640 letterboxed frame, "
                    "then objectness and class score after sigmoid; NMS is applied by the consumer"
                ),
                "observed_shape": io_spec["outputs"][0]["shape"],
                "num_classes_configured": metadata["num_classes"],
            },
        },
        "training": {
            "exp_file": str(exp_file),
            "depth": metadata["depth"],
            "width": metadata["width"],
            "test_size": metadata["test_size"],
            "recipe": "tools/train/README.md section 'D1 comparison run: YOLOX-Nano' (batch 4, workers 0, 40 epochs)",
        },
        "build_host": {"platform": platform.platform(), "machine": platform.machine()},
    }
    write_json(manifest_path, manifest)
    print(f"ONNX artifact: {onnx_path} ({manifest['model']['file_bytes']} bytes)")
    print(f"sha256: {manifest['model']['sha256']}")
    print(f"outputs: {io_spec['outputs']}")
    print(f"Manifest written to {manifest_path}")


def main() -> None:
    """Entry point for the YOLOX ONNX export (run under .venv-yolox)."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--exp-file",
        type=Path,
        default=PROJECT_ROOT / "configs" / "yolox_d1.py",
        help="experiment file that builds the depthwise YOLOX-Nano",
    )
    parser.add_argument(
        "--checkpoint",
        type=Path,
        default=ARTIFACTS_DIR / "train_yolox_d1" / "yolox_d1" / "best_ckpt.pth",
    )
    parser.add_argument("--output", type=Path, default=ARTIFACTS_DIR / "holds_detector_yolox_d1.onnx")
    parser.add_argument("--manifest", type=Path, default=ARTIFACTS_DIR / "manifest_yolox_d1.json")
    parser.add_argument("--opset", type=int, default=DEFAULT_OPSET)
    parser.add_argument("--resolution", type=int, default=DEFAULT_RESOLUTION)
    parser.add_argument("--id", dest="artifact_id", default="holds_detector_yolox_d1")
    parser.add_argument("--version", dest="artifact_version", default="1.0.0")
    parser.add_argument(
        "--purpose",
        dest="artifact_purpose",
        default=(
            "Phase 4 D1 comparison candidate: YOLOX-Nano trained 40 epochs on merged D1 "
            "(train 1804, val 591), best checkpoint (epoch 40), export for ONNX parity"
        ),
    )
    args = parser.parse_args()

    if not args.checkpoint.exists():
        raise SystemExit(f"Checkpoint not found: {args.checkpoint}. Run the YOLOX D1 training first.")
    if not args.exp_file.exists():
        raise SystemExit(f"Exp file not found: {args.exp_file}")
    print(f"Exporting from checkpoint: {args.checkpoint}")
    export_artifact(
        exp_file=args.exp_file,
        checkpoint_path=args.checkpoint,
        onnx_path=args.output,
        manifest_path=args.manifest,
        opset=args.opset,
        resolution=args.resolution,
        artifact_id=args.artifact_id,
        artifact_version=args.artifact_version,
        artifact_purpose=args.artifact_purpose,
    )


if __name__ == "__main__":
    main()
