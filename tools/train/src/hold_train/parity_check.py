"""PyTorch versus onnxruntime numeric parity for a hold detector export.

Runs K fixed validation images through both the PyTorch checkpoint and the
exported ONNX under onnxruntime and checks that the export reproduces the model.
This is the export fidelity gate that must pass before the single gated
frozen-test-split evaluation; it touches only the val split.

Parity is judged on the tensors the eval harness actually consumes, not on raw
max-abs across every query. RF-DETR emits 300 queries, but only a handful carry
meaningful hold score; the box coordinates of near-zero background queries are
numerically ill-conditioned and irrelevant to detection. So the check reports:

  - raw max absolute / relative difference per output (diagnostic), and
  - a decision-space check mirroring decode.ts: per-query hold score (channel-0
    sigmoid) agreement, plus box agreement restricted to queries where either
    side predicts a hold score above --score-threshold (default 0.5).

Export fidelity is real when the decision-space metrics stay within tolerance;
background-query box jitter alone is not a parity failure.

Each model carries its own preprocess contract, so the correct normalization is
applied per model:

  - RF-DETR: ImageNet (value / 255 - mean) / std, matching the shared harness
    contract in tools/eval/src/preprocess.ts and the training transform.
  - YOLOX: raw 0..255 RGB, no normalization, matching the YOLOX preproc used in
    training (cv2 reads BGR, the preproc flips to RGB).

Both models consume images that hold-bake already letterboxed to 640x640 with
pad value 114, so no letterbox resize is applied here (it would be an identity
step on that data).

Run under the matching environment from tools/train, for example:

    PYTHONPATH=src .venv/bin/python -m hold_train.parity_check \
        --model rfdetr --checkpoint artifacts/train_rf_detr_d1/checkpoint_best_total.pth \
        --onnx artifacts/holds_detector_d1.onnx

    PYTHONPATH=src .venv-yolox/bin/python -m hold_train.parity_check \
        --model yolox --checkpoint artifacts/train_yolox_d1/yolox_d1/best_ckpt.pth \
        --onnx artifacts/holds_detector_yolox_d1.onnx --exp-file configs/yolox_d1.py

Exit code is 0 when the decision-space metrics stay within --tolerance, else 1.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import numpy as np
import onnxruntime as ort
import torch

from .common import ARTIFACTS_DIR, PROJECT_ROOT, write_json

IMAGENET_MEAN = np.array([0.485, 0.456, 0.406], dtype=np.float32)
IMAGENET_STD = np.array([0.229, 0.224, 0.225], dtype=np.float32)
DEFAULT_TOLERANCE = 1e-3
DEFAULT_SCORE_THRESHOLD = 0.5
DEFAULT_RESOLUTION = 640


def _sigmoid(x: np.ndarray) -> np.ndarray:
    """Numerically stable sigmoid."""
    return np.where(x >= 0, 1 / (1 + np.exp(-np.abs(x))), np.exp(-np.abs(x)) / (1 + np.exp(-np.abs(x))))


def _parity_metrics(
    model: str,
    output_names: list[str],
    torch_outs: list[np.ndarray],
    onnx_outs: list[np.ndarray],
    score_threshold: float,
) -> dict[str, Any]:
    """Compare torch and ONNX outputs for one image.

    Always reports raw max-abs / max-rel per output (diagnostic). For RF-DETR also
    reports a decision-space check mirroring decode.ts: hold score (channel-0
    sigmoid) agreement across all queries, plus box agreement restricted to
    queries where either side scores above score_threshold.
    """
    raw: dict[str, dict[str, float]] = {}
    for name, t, o in zip(output_names, torch_outs, onnx_outs):
        tf = t.astype(np.float64)
        of = o.astype(np.float64)
        max_abs = float(np.max(np.abs(tf - of)))
        denom = max(float(np.max(np.abs(tf))), 1e-12)
        raw[name] = {"max_abs": max_abs, "max_rel": max_abs / denom}

    result: dict[str, Any] = {"raw": raw}
    if model == "rfdetr":
        boxes = dict(zip(output_names, torch_outs))["dets"].astype(np.float64)[0]
        oboxes = dict(zip(output_names, onnx_outs))["dets"].astype(np.float64)[0]
        logits = dict(zip(output_names, torch_outs))["labels"].astype(np.float64)[0]
        ologits = dict(zip(output_names, onnx_outs))["labels"].astype(np.float64)[0]
        hold = _sigmoid(logits[:, 0])
        ohold = _sigmoid(ologits[:, 0])
        score_diff = float(np.max(np.abs(hold - ohold)))
        active = (hold > score_threshold) | (ohold > score_threshold)
        if active.any():
            box_diff = float(np.max(np.abs(boxes[active] - oboxes[active])))
            n_active = int(active.sum())
        else:
            box_diff = 0.0
            n_active = 0
        result["decision"] = {
            "max_hold_score_diff": score_diff,
            "active_queries": n_active,
            "max_active_box_diff": box_diff,
            "score_threshold": score_threshold,
        }
    elif model == "yolox":
        # output [1, anchors, 6] = cx cy w h objectness class; the harness consumer
        # thresholds objectness*class and applies NMS, so compare those scores plus
        # the boxes of score-bearing anchors.
        t = dict(zip(output_names, torch_outs))[output_names[0]].astype(np.float64)[0]
        o = dict(zip(output_names, onnx_outs))[output_names[0]].astype(np.float64)[0]
        # YOLOX emits boxes in pixels of the 640x640 letterboxed frame; RF-DETR
        # emits normalized 0..1. Convert to the normalized frame so one absolute
        # tolerance means the same thing for both models.
        t[:, :4] /= DEFAULT_RESOLUTION
        o[:, :4] /= DEFAULT_RESOLUTION
        tscore = t[:, 4] * t[:, 5]
        oscore = o[:, 4] * o[:, 5]
        score_diff = float(np.max(np.abs(tscore - oscore)))
        active = (tscore > score_threshold) | (oscore > score_threshold)
        if active.any():
            box_diff = float(np.max(np.abs(t[active, :4] - o[active, :4])))
            n_active = int(active.sum())
        else:
            box_diff = 0.0
            n_active = 0
        result["decision"] = {
            "max_score_diff": score_diff,
            "active_anchors": n_active,
            "max_active_box_diff": box_diff,
            "score_threshold": score_threshold,
        }
    return result


def _preprocess(img_path: Path, model: str) -> np.ndarray:
    """Return a 1x3x640x640 float32 NCHW tensor under the model's contract."""
    from PIL import Image

    with Image.open(img_path) as img:
        rgb = np.asarray(img.convert("RGB"), dtype=np.float32)
    if rgb.shape[0] != 640 or rgb.shape[1] != 640:
        raise ValueError(f"{img_path.name}: expected a pre-letterboxed 640x640 image, got {rgb.shape}")
    chw = rgb.transpose(2, 0, 1)
    if model == "rfdetr":
        chw = (chw / 255.0 - IMAGENET_MEAN[:, None, None]) / IMAGENET_STD[:, None, None]
    elif model == "yolox":
        pass  # raw 0..255 RGB, as trained
    else:
        raise ValueError(f"unknown model kind: {model}")
    return chw[None].astype(np.float32)


def _pick_images(split_dir: Path, count: int) -> list[Path]:
    """Deterministic sample of validation images, sorted by name."""
    images = sorted(split_dir.glob("images/*.jpg"))
    if not images:
        raise SystemExit(f"no .jpg images under {split_dir}/images")
    if count > len(images):
        count = len(images)
    step = max(1, len(images) // count)
    return images[::step][:count]


def _run_torch(
    model: str, checkpoint: Path, exp_file: Path | None, batch: torch.Tensor
) -> tuple[list[np.ndarray], np.ndarray]:
    """Run the PyTorch model.

    Returns (outputs in ONNX output order, the exact input fed). For RF-DETR the
    input is the graph's own example tensor (built by prepare_export_graph), so
    the caller can feed that same array to the ONNX session for a true like-for-like
    comparison.
    """
    with torch.no_grad():
        if model == "rfdetr":
            from rfdetr import RFDETR

            rf = RFDETR.from_checkpoint(str(checkpoint))
            # rf.model is a ModelContext wrapper; the nn.Module is rf.model.model (LWDETR).
            # LWDETR.export() sets _export and swaps every submodule's forward to its
            # forward_export variant (recursively via named_modules), so the backbone
            # consumes a plain tensor and the graph matches what the exporter traced.
            lw = rf.model.model
            lw.eval()
            lw.export()
            boxes, logits = lw(batch)
            return [boxes.detach().cpu().numpy(), logits.detach().cpu().numpy()], batch.detach().cpu().numpy()
        if model == "yolox":
            from yolox.exp import get_exp

            if exp_file is None:
                raise SystemExit("--exp-file is required for --model yolox")
            exp = get_exp(str(exp_file))
            ymodel = exp.get_model()
            ckpt = torch.load(checkpoint, map_location="cpu", weights_only=False)
            state = ckpt["model"] if isinstance(ckpt, dict) and "model" in ckpt else ckpt
            ymodel.load_state_dict(state, strict=True)
            ymodel.head.decode_in_inference = True
            ymodel.eval()
            out = ymodel(batch)
            return [out.cpu().numpy()], batch.detach().cpu().numpy()
    raise ValueError(f"unknown model kind: {model}")


def main() -> None:
    """Compare torch and onnxruntime outputs on K validation images."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", choices=["rfdetr", "yolox"], required=True)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--onnx", type=Path, required=True)
    parser.add_argument("--exp-file", type=Path, default=None)
    parser.add_argument("--split-dir", type=Path, default=PROJECT_ROOT / "datasets" / "merged" / "val")
    parser.add_argument("--count", type=int, default=5, help="number of validation images to compare")
    parser.add_argument("--tolerance", type=float, default=DEFAULT_TOLERANCE)
    parser.add_argument(
        "--score-threshold",
        type=float,
        default=DEFAULT_SCORE_THRESHOLD,
        help="hold score above which a query/anchor is considered active for the decision-space box check",
    )
    parser.add_argument("--report", type=Path, default=None)
    args = parser.parse_args()

    if not args.onnx.exists():
        raise SystemExit(f"ONNX not found: {args.onnx}")
    if not args.checkpoint.exists():
        raise SystemExit(f"checkpoint not found: {args.checkpoint}")

    session = ort.InferenceSession(str(args.onnx), providers=["CPUExecutionProvider"])
    input_name = session.get_inputs()[0].name
    output_names = [o.name for o in session.get_outputs()]
    images = _pick_images(args.split_dir, args.count)

    per_output_max_abs = np.zeros(len(output_names), dtype=np.float64)
    per_output_max_rel = np.zeros(len(output_names), dtype=np.float64)
    max_score_diff = 0.0
    max_active_box_diff = 0.0
    rows: list[dict[str, Any]] = []

    print(f"model={args.model} images={len(images)} tolerance={args.tolerance:g} "
          f"score_threshold={args.score_threshold:g}")
    for img_path in images:
        batch_np = _preprocess(img_path, args.model)
        torch_outs, fed_input = _run_torch(args.model, args.checkpoint, args.exp_file, torch.from_numpy(batch_np))
        # Feed the exact tensor the torch model saw, so the comparison is like-for-like.
        onnx_outs = session.run(output_names, {input_name: fed_input})
        metrics = _parity_metrics(args.model, output_names, torch_outs, onnx_outs, args.score_threshold)
        for index, name in enumerate(output_names):
            per_output_max_abs[index] = max(per_output_max_abs[index], metrics["raw"][name]["max_abs"])
            per_output_max_rel[index] = max(per_output_max_rel[index], metrics["raw"][name]["max_rel"])
        decision = metrics["decision"]
        score_key = "max_hold_score_diff" if args.model == "rfdetr" else "max_score_diff"
        max_score_diff = max(max_score_diff, float(decision[score_key]))
        max_active_box_diff = max(max_active_box_diff, float(decision["max_active_box_diff"]))
        rows.append({"image": img_path.name, **metrics})
        print(
            f"  {img_path.name}: score_diff={decision[score_key]:.3e} "
            f"active_box_diff={decision['max_active_box_diff']:.3e} "
            f"active={decision.get('active_queries', decision.get('active_anchors'))}"
        )

    # Gate on the decision-space metrics the harness consumes; raw tensor deltas
    # on background queries are recorded for diagnosis only.
    passed = max_score_diff <= args.tolerance and max_active_box_diff <= args.tolerance
    summary = {
        "model": args.model,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "checkpoint": str(args.checkpoint),
        "onnx": str(args.onnx),
        "onnx_bytes": args.onnx.stat().st_size,
        "images_compared": len(rows),
        "tolerance": args.tolerance,
        "score_threshold": args.score_threshold,
        "passed": passed,
        "decision": {
            "max_score_diff": max_score_diff,
            "max_active_box_diff": max_active_box_diff,
        },
        "per_output_max_abs": {n: float(m) for n, m in zip(output_names, per_output_max_abs)},
        "per_output_max_rel": {n: float(m) for n, m in zip(output_names, per_output_max_rel)},
        "detail": rows,
    }
    report_path = args.report or (ARTIFACTS_DIR / f"parity_{args.model}_d1.json")
    write_json(report_path, summary)

    print("RESULT (max over images):")
    print(f"  decision max_score_diff={max_score_diff:.6e} max_active_box_diff={max_active_box_diff:.6e}")
    for name, m_abs, m_rel in zip(output_names, per_output_max_abs, per_output_max_rel):
        print(f"  raw {name}: max_abs={m_abs:.6e} max_rel={m_rel:.6e}")
    print(f"{'PASS' if passed else 'FAIL'} (tolerance {args.tolerance:g})")
    print(f"report written to {report_path}")
    raise SystemExit(0 if passed else 1)


if __name__ == "__main__":
    main()
