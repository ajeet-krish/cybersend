"""Core ML versus ONNX parity for the RF-DETR hold detector.

The Core ML package is the deployment copy; the ONNX graph is the canonical
artifact that already passed torch parity. This tool feeds both runtimes the
same preprocessed val images and applies the same decision-space gate used in
parity_check.py: hold scores plus boxes over queries above the threshold.

It touches val only, never the frozen test split.

Run with the training environment plus coremltools, from tools/train:

    PYTHONPATH=src .venv/bin/python -m hold_train.parity_coreml \
        --mlpackage artifacts/coreml_rfdetr_d1/rfdetr-nano_fp32.mlpackage \
        --onnx artifacts/holds_detector_d1.onnx

The .mlpackage input is named "tensors" and its outputs are internal MIL names
("concat_2" for dets, "linear_102" for labels), so the mapping below is explicit
and shape checked rather than assumed by position.
"""

from __future__ import annotations

import argparse
import statistics
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import numpy as np
import onnxruntime as ort
import coremltools as ct

from .common import ARTIFACTS_DIR, write_json
from .parity_check import (
    DEFAULT_SCORE_THRESHOLD,
    DEFAULT_TOLERANCE,
    _parity_metrics,
    _pick_images,
    _preprocess,
    _sigmoid,
)


def _detections(
    dets: np.ndarray,
    labels: np.ndarray,
    threshold: float,
    resolution: int = 640,
) -> list[tuple[float, float, float, float, float]]:
    """Decode normalized cxcywh boxes plus hold logits into pixel xyxy detections."""
    boxes = np.asarray(dets, dtype=np.float64)[0]
    logits = np.asarray(labels, dtype=np.float64)[0]
    scores = _sigmoid(logits[:, 0])
    rows: list[tuple[float, float, float, float, float]] = []
    for index in np.nonzero(scores >= threshold)[0]:
        cx, cy, width, height = boxes[index]
        rows.append(
            (
                float(scores[index]),
                float((cx - width / 2) * resolution),
                float((cy - height / 2) * resolution),
                float((cx + width / 2) * resolution),
                float((cy + height / 2) * resolution),
            )
        )
    rows.sort(key=lambda row: -row[0])
    return rows


def _iou(a: tuple[float, float, float, float, float], b: tuple[float, float, float, float, float]) -> float:
    """IoU of two (score, x1, y1, x2, y2) rows."""
    ix1, iy1 = max(a[1], b[1]), max(a[2], b[2])
    ix2, iy2 = min(a[3], b[3]), min(a[4], b[4])
    inter = max(0.0, ix2 - ix1) * max(0.0, iy2 - iy1)
    if inter <= 0:
        return 0.0
    area_a = max(0.0, a[3] - a[1]) * max(0.0, a[4] - a[2])
    area_b = max(0.0, b[3] - b[1]) * max(0.0, b[4] - b[2])
    union = area_a + area_b - inter
    return inter / union if union > 0 else 0.0


def _agreement(
    reference: list[tuple[float, float, float, float, float]],
    prediction: list[tuple[float, float, float, float, float]],
    iou_threshold: float = 0.5,
) -> dict[str, int]:
    """Greedy match prediction detections to reference detections at IoU 0.5."""
    claimed = [False] * len(reference)
    matched = 0
    for row in prediction:
        best_index = -1
        best_iou = iou_threshold
        for index, ref in enumerate(reference):
            if claimed[index]:
                continue
            overlap = _iou(row, ref)
            if overlap >= best_iou:
                best_iou = overlap
                best_index = index
        if best_index >= 0:
            claimed[best_index] = True
            matched += 1
    return {
        "matched": matched,
        "extra": len(prediction) - matched,
        "missing": len(reference) - matched,
        "reference": len(reference),
        "prediction": len(prediction),
    }


def _run_coreml(model: ct.models.MLModel, batch: np.ndarray) -> tuple[list[np.ndarray], float]:
    """Run one image through the Core ML package, returning dets and labels plus latency."""
    input_name = model.get_spec().description.input[0].name
    start = time.perf_counter()
    outputs = model.predict({input_name: batch})
    elapsed_ms = (time.perf_counter() - start) * 1000.0
    dets = None
    labels = None
    for value in outputs.values():
        array = np.asarray(value, dtype=np.float32)
        if array.ndim == 3 and array.shape[2] == 4:
            dets = array
        elif array.ndim == 3 and array.shape[2] >= 2:
            labels = array
    if dets is None or labels is None:
        raise SystemExit(f"unexpected Core ML outputs: {[np.asarray(v).shape for v in outputs.values()]}")
    return [dets, labels], elapsed_ms


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mlpackage", type=Path, required=True)
    parser.add_argument("--onnx", type=Path, required=True)
    parser.add_argument("--split-dir", type=Path, default=ARTIFACTS_DIR.parent / "datasets" / "merged" / "val")
    parser.add_argument("--count", type=int, default=5)
    parser.add_argument("--tolerance", type=float, default=DEFAULT_TOLERANCE)
    parser.add_argument("--score-threshold", type=float, default=DEFAULT_SCORE_THRESHOLD)
    parser.add_argument(
        "--compute-units",
        default="CPU_AND_NE",
        choices=["ALL", "CPU_AND_NE", "CPU_AND_GPU", "CPU_ONLY"],
        help="Core ML compute units for the runtime check",
    )
    parser.add_argument("--report", type=Path, default=None)
    parser.add_argument(
        "--agreement",
        action="store_true",
        help="also compare decoded detection sets (thresholded, greedy IoU 0.5 match), "
        "which is what the app consumes; the per-query gate stays as reported",
    )
    parser.add_argument(
        "--agreement-threshold",
        type=float,
        default=0.5,
        help="hold score threshold for the detection agreement check",
    )
    parser.add_argument(
        "--agreement-tolerance",
        type=float,
        default=0.02,
        help="maximum share of reference detections that may change (extra plus "
        "missing) for the agreement gate to pass; only used with --agreement",
    )
    args = parser.parse_args()

    units = getattr(ct.ComputeUnit, args.compute_units)
    model = ct.models.MLModel(str(args.mlpackage), compute_units=units)
    session = ort.InferenceSession(str(args.onnx), providers=["CPUExecutionProvider"])
    onnx_names = [o.name for o in session.get_outputs()]
    images = _pick_images(args.split_dir, args.count)
    if not images:
        raise SystemExit(f"no images found under {args.split_dir}")

    output_names = ["dets", "labels"]
    rows: list[dict[str, Any]] = []
    max_score_diff = 0.0
    max_active_box_diff = 0.0
    latencies: list[float] = []
    agreement_totals = {"matched": 0, "extra": 0, "missing": 0, "reference": 0, "prediction": 0}

    print(f"mlpackage={args.mlpackage.name} images={len(images)} units={args.compute_units} "
          f"tolerance={args.tolerance:g}")
    for image_path in images:
        batch = _preprocess(image_path, "rfdetr")
        onnx_outs = session.run(onnx_names, {session.get_inputs()[0].name: batch})
        coreml_outs, latency_ms = _run_coreml(model, batch)
        latencies.append(latency_ms)
        metrics = _parity_metrics("rfdetr", output_names, onnx_outs, coreml_outs, args.score_threshold)
        decision = metrics["decision"]
        max_score_diff = max(max_score_diff, float(decision["max_hold_score_diff"]))
        max_active_box_diff = max(max_active_box_diff, float(decision["max_active_box_diff"]))
        row: dict[str, Any] = {"image": image_path.name, **metrics, "coreml_ms": latency_ms}
        if args.agreement:
            onnx_map = dict(zip(output_names, onnx_outs))
            coreml_map = dict(zip(output_names, coreml_outs))
            reference = _detections(onnx_map["dets"], onnx_map["labels"], args.agreement_threshold)
            prediction = _detections(coreml_map["dets"], coreml_map["labels"], args.agreement_threshold)
            agreement = _agreement(reference, prediction)
            row["agreement"] = agreement
            for key in agreement_totals:
                agreement_totals[key] += agreement[key]
            print(
                f"  {image_path.name}: score_diff={decision['max_hold_score_diff']:.3e} "
                f"active_box_diff={decision['max_active_box_diff']:.3e} "
                f"active={decision['active_queries']} coreml={latency_ms:.1f}ms "
                f"dets ref={agreement['reference']} pred={agreement['prediction']} "
                f"matched={agreement['matched']} extra={agreement['extra']} missing={agreement['missing']}"
            )
        else:
            print(
                f"  {image_path.name}: score_diff={decision['max_hold_score_diff']:.3e} "
                f"active_box_diff={decision['max_active_box_diff']:.3e} "
                f"active={decision['active_queries']} coreml={latency_ms:.1f}ms"
            )
        rows.append(row)

    if args.agreement:
        total_ref = max(1, agreement_totals["reference"])
        changed_share = (agreement_totals["extra"] + agreement_totals["missing"]) / total_ref
        passed = changed_share <= args.agreement_tolerance
    else:
        changed_share = None
        passed = max_score_diff <= args.tolerance and max_active_box_diff <= args.tolerance
    summary = {
        "runtime": "coreml",
        "created_at": datetime.now(timezone.utc).isoformat(),
        "mlpackage": str(args.mlpackage),
        "onnx": str(args.onnx),
        "compute_units": args.compute_units,
        "images_compared": len(rows),
        "tolerance": args.tolerance,
        "score_threshold": args.score_threshold,
        "passed": passed,
        "gate": "detection agreement" if args.agreement else "per-query decision space",
        "agreement_tolerance": args.agreement_tolerance if args.agreement else None,
        "decision": {
            "max_hold_score_diff": max_score_diff,
            "max_active_box_diff": max_active_box_diff,
        },
        "latency_ms": {
            "median": statistics.median(latencies),
            "min": min(latencies),
            "max": max(latencies),
        },
        "agreement": agreement_totals if args.agreement else None,
        "agreement_changed_share": changed_share,
        "detail": rows,
    }
    report_path = args.report or (ARTIFACTS_DIR / "parity_coreml_rfdetr_d1.json")
    write_json(report_path, summary)

    print("RESULT (max over images):")
    print(f"  decision max_hold_score_diff={max_score_diff:.6e} max_active_box_diff={max_active_box_diff:.6e}")
    print(f"  coreml latency median={statistics.median(latencies):.1f}ms "
          f"min={min(latencies):.1f}ms max={max(latencies):.1f}ms ({args.compute_units})")
    if args.agreement:
        print(
            f"  detection agreement: reference={agreement_totals['reference']} "
            f"prediction={agreement_totals['prediction']} matched={agreement_totals['matched']} "
            f"extra={agreement_totals['extra']} missing={agreement_totals['missing']} "
            f"changed_share={(changed_share or 0.0):.4%} (limit {args.agreement_tolerance:.2%})"
        )
        print(
            f"  per-query diagnostic (not the gate): max_hold_score_diff={max_score_diff:.3e} "
            f"max_active_box_diff={max_active_box_diff:.3e}"
        )
    print(
        f"{'PASS' if passed else 'FAIL'} "
        f"({'detection agreement' if args.agreement else f'tolerance {args.tolerance:g}'})"
    )
    print(f"report written to {report_path}")
    raise SystemExit(0 if passed else 1)


if __name__ == "__main__":
    main()
