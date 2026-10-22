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
)


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
        rows.append({"image": image_path.name, **metrics, "coreml_ms": latency_ms})
        print(
            f"  {image_path.name}: score_diff={decision['max_hold_score_diff']:.3e} "
            f"active_box_diff={decision['max_active_box_diff']:.3e} "
            f"active={decision['active_queries']} coreml={latency_ms:.1f}ms"
        )

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
        "decision": {
            "max_hold_score_diff": max_score_diff,
            "max_active_box_diff": max_active_box_diff,
        },
        "latency_ms": {
            "median": statistics.median(latencies),
            "min": min(latencies),
            "max": max(latencies),
        },
        "detail": rows,
    }
    report_path = args.report or (ARTIFACTS_DIR / "parity_coreml_rfdetr_d1.json")
    write_json(report_path, summary)

    print("RESULT (max over images):")
    print(f"  decision max_hold_score_diff={max_score_diff:.6e} max_active_box_diff={max_active_box_diff:.6e}")
    print(f"  coreml latency median={statistics.median(latencies):.1f}ms "
          f"min={min(latencies):.1f}ms max={max(latencies):.1f}ms ({args.compute_units})")
    print(f"{'PASS' if passed else 'FAIL'} (tolerance {args.tolerance:g})")
    print(f"report written to {report_path}")
    raise SystemExit(0 if passed else 1)


if __name__ == "__main__":
    main()
