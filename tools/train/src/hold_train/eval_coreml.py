"""Score a Core ML package against the ONNX graph on the same split.

parity_coreml.py answers "do the tensors agree"; this tool answers "does the
model detect the same holds". It runs both runtimes over a COCO split, decodes
the RF-DETR outputs with the same rule as tools/eval/src/decode.ts (sigmoid on
channel 0, normalized cxcywh to pixels, no NMS), and computes the operating
point metrics the Phase 4 criteria use: precision, recall, mAP@0.5, false
positives per image, and median absolute count error.

This is the deployment gate that matters for a compressed package. The
per-query parity metric in parity_coreml.py is deliberately strict about every
one of the 300 queries, including background queries whose boxes are meaningless,
so a package can fail it while producing the same detections. Accuracy through
the runtime settles that without arguing about tolerances.

Val only. The frozen test split is refused by path, matching the harness policy.

Run from tools/train with the training environment:

    PYTHONPATH=src .venv/bin/python -m hold_train.eval_coreml \\
        --mlpackage artifacts/coreml_rfdetr_d1/rfdetr-nano_int8kmeanstensor.mlpackage \\
        --onnx artifacts/holds_detector_d1.onnx --confidence 0.765
"""

from __future__ import annotations

import argparse
import json
import statistics
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import numpy as np
import onnxruntime as ort
import coremltools as ct

from .common import ARTIFACTS_DIR, write_json
from .parity_check import _preprocess, _sigmoid
from .parity_coreml import _detections, _run_coreml

RESOLUTION = 640
SCORE_FLOOR = 1e-4


def _load_split(split_dir: Path) -> tuple[list[dict[str, Any]], dict[int, list[tuple[float, float, float, float]]]]:
    """Read the COCO annotation file and return images plus ground truth xyxy boxes."""
    coco = json.loads((split_dir / "_annotations.coco.json").read_text())
    gt: dict[int, list[tuple[float, float, float, float]]] = {}
    for annotation in coco["annotations"]:
        x, y, width, height = annotation["bbox"]
        gt.setdefault(annotation["image_id"], []).append((x, y, x + width, y + height))
    return coco["images"], gt


def _iou(a: tuple[float, float, float, float], b: tuple[float, float, float, float]) -> float:
    ix1, iy1 = max(a[0], b[0]), max(a[1], b[1])
    ix2, iy2 = min(a[2], b[2]), min(a[3], b[3])
    inter = max(0.0, ix2 - ix1) * max(0.0, iy2 - iy1)
    if inter <= 0:
        return 0.0
    area_a = max(0.0, a[2] - a[0]) * max(0.0, a[3] - a[1])
    area_b = max(0.0, b[2] - b[0]) * max(0.0, b[3] - b[1])
    union = area_a + area_b - inter
    return inter / union if union > 0 else 0.0


def _match(
    detections: list[tuple[float, float, float, float, float]],
    ground_truth: list[tuple[float, float, float, float]],
    iou_threshold: float,
) -> tuple[list[bool], int]:
    """Greedy confidence-ordered matching; returns TP flags and the TP count."""
    claimed = [False] * len(ground_truth)
    flags: list[bool] = []
    for row in detections:
        best_index = -1
        best_iou = iou_threshold
        for index, box in enumerate(ground_truth):
            if claimed[index]:
                continue
            overlap = _iou((row[1], row[2], row[3], row[4]), box)
            if overlap >= best_iou:
                best_iou = overlap
                best_index = index
        if best_index >= 0:
            claimed[best_index] = True
            flags.append(True)
        else:
            flags.append(False)
    return flags, sum(flags)


def _average_precision(flags: list[bool], total_ground_truths: int) -> float:
    """VOC 2010+ all-point interpolated AP, same definition as the harness."""
    if total_ground_truths == 0 or not flags:
        return 0.0
    precisions: list[float] = []
    recalls: list[float] = []
    tp = 0
    fp = 0
    for flag in flags:
        if flag:
            tp += 1
        else:
            fp += 1
        precisions.append(tp / (tp + fp))
        recalls.append(tp / total_ground_truths)
    suffix_max = [0.0] * len(precisions)
    running = 0.0
    for index in range(len(precisions) - 1, -1, -1):
        running = max(running, precisions[index])
        suffix_max[index] = running
    ap = 0.0
    previous = 0.0
    for index, recall in enumerate(recalls):
        if recall > previous:
            ap += (recall - previous) * suffix_max[index]
            previous = recall
    return ap


def _score(
    per_image: dict[int, list[tuple[float, float, float, float, float]]],
    ground_truth: dict[int, list[tuple[float, float, float, float]]],
    image_ids: list[int],
    confidence: float,
    iou_threshold: float,
) -> dict[str, Any]:
    """Compute the Phase 4 operating metrics for one runtime's detections."""
    # mAP needs one globally score-ranked list, not per-image lists concatenated
    # in image order: the precision envelope is built over the pooled ranking.
    pooled: list[tuple[float, int, tuple[float, float, float, float, float]]] = []
    for image_id in image_ids:
        for row in per_image.get(image_id, []):
            pooled.append((row[0], image_id, row))
    pooled.sort(key=lambda entry: -entry[0])
    claimed: dict[int, list[bool]] = {
        image_id: [False] * len(ground_truth.get(image_id, [])) for image_id in image_ids
    }
    all_flags: list[bool] = []
    for _, image_id, row in pooled:
        truth = ground_truth.get(image_id, [])
        row_claimed = claimed[image_id]
        best_index = -1
        best_iou = iou_threshold
        for index, box in enumerate(truth):
            if row_claimed[index]:
                continue
            overlap = _iou((row[1], row[2], row[3], row[4]), box)
            if overlap >= best_iou:
                best_iou = overlap
                best_index = index
        if best_index >= 0:
            row_claimed[best_index] = True
            all_flags.append(True)
        else:
            all_flags.append(False)

    operating_tp = 0
    operating_fp = 0
    count_errors: list[int] = []
    for image_id in image_ids:
        rows = sorted(per_image.get(image_id, []), key=lambda row: -row[0])
        truth = ground_truth.get(image_id, [])
        operating = [row for row in rows if row[0] >= confidence]
        op_flags, op_tp = _match(operating, truth, iou_threshold)
        operating_tp += op_tp
        operating_fp += len(op_flags) - op_tp
        count_errors.append(abs(len(operating) - len(truth)))
    total_gt = sum(len(ground_truth.get(image_id, [])) for image_id in image_ids)
    return {
        "precision": round(operating_tp / max(1, operating_tp + operating_fp), 4),
        "recall": round(operating_tp / max(1, total_gt), 4),
        "map05": round(_average_precision(all_flags, total_gt), 4),
        "tp": operating_tp,
        "fp": operating_fp,
        "fn": total_gt - operating_tp,
        "false_positives_per_image": round(operating_fp / max(1, len(image_ids)), 4),
        "median_abs_count_error": statistics.median(count_errors) if count_errors else 0,
        "ground_truth": total_gt,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mlpackage", type=Path, required=True)
    parser.add_argument("--onnx", type=Path, required=True)
    parser.add_argument("--split-dir", type=Path, default=ARTIFACTS_DIR.parent / "datasets" / "merged" / "val")
    parser.add_argument("--confidence", type=float, default=0.5)
    parser.add_argument("--iou", type=float, default=0.5)
    parser.add_argument("--limit", type=int, default=0, help="images to score, 0 means all")
    parser.add_argument("--compute-units", default="CPU_AND_NE", choices=["ALL", "CPU_AND_NE", "CPU_AND_GPU", "CPU_ONLY"])
    parser.add_argument("--report", type=Path, default=None)
    args = parser.parse_args()

    if args.split_dir.name == "test":
        raise SystemExit(
            "eval_coreml: refusing to score the frozen test split; "
            "Core ML validation happens on val (see tools/eval/README.md)"
        )

    images, ground_truth = _load_split(args.split_dir)
    if args.limit > 0:
        images = images[: args.limit]

    model = ct.models.MLModel(str(args.mlpackage), compute_units=getattr(ct.ComputeUnit, args.compute_units))
    session = ort.InferenceSession(str(args.onnx), providers=["CPUExecutionProvider"])
    onnx_names = [output.name for output in session.get_outputs()]
    input_name = session.get_inputs()[0].name

    coreml_dets: dict[int, list[tuple[float, float, float, float, float]]] = {}
    onnx_dets: dict[int, list[tuple[float, float, float, float, float]]] = {}
    latencies: list[float] = []

    print(f"mlpackage={args.mlpackage.name} images={len(images)} confidence={args.confidence} iou={args.iou}")
    for index, image in enumerate(images):
        path = args.split_dir / image["file_name"]
        batch = _preprocess(path, "rfdetr")
        onnx_outs = session.run(onnx_names, {input_name: batch})
        coreml_outs, latency_ms = _run_coreml(model, batch)
        latencies.append(latency_ms)
        onnx_map = dict(zip(onnx_names, onnx_outs))
        coreml_map = dict(zip(onnx_names, coreml_outs))
        onnx_dets[image["id"]] = _detections(onnx_map["dets"], onnx_map["labels"], SCORE_FLOOR, RESOLUTION)
        coreml_dets[image["id"]] = _detections(coreml_map["dets"], coreml_map["labels"], SCORE_FLOOR, RESOLUTION)
        if (index + 1) % 100 == 0:
            print(f"  scored {index + 1}/{len(images)}")

    image_ids = [image["id"] for image in images]
    onnx_metrics = _score(onnx_dets, ground_truth, image_ids, args.confidence, args.iou)
    coreml_metrics = _score(coreml_dets, ground_truth, image_ids, args.confidence, args.iou)

    deltas = {
        key: round(coreml_metrics[key] - onnx_metrics[key], 4)
        for key in ("precision", "recall", "map05", "false_positives_per_image", "median_abs_count_error")
    }

    summary = {
        "created_at": datetime.now(timezone.utc).isoformat(),
        "mlpackage": str(args.mlpackage),
        "onnx": str(args.onnx),
        "split_dir": str(args.split_dir),
        "images": len(images),
        "confidence": args.confidence,
        "iou": args.iou,
        "compute_units": args.compute_units,
        "onnx_metrics": onnx_metrics,
        "coreml_metrics": coreml_metrics,
        "delta_coreml_minus_onnx": deltas,
        "latency_ms": {
            "median": round(statistics.median(latencies), 1),
            "min": round(min(latencies), 1),
            "max": round(max(latencies), 1),
        },
    }
    report_path = args.report or (ARTIFACTS_DIR / "eval_coreml_rfdetr.json")
    write_json(report_path, summary)

    header = f"{'metric':32s} {'onnx':>10s} {'coreml':>10s} {'delta':>8s}"
    print("--- accuracy through each runtime ---")
    print(header)
    for key in ("precision", "recall", "map05", "false_positives_per_image", "median_abs_count_error"):
        print(f"{key:32s} {onnx_metrics[key]:>10} {coreml_metrics[key]:>10} {deltas[key]:>8}")
    print(f"latency median {statistics.median(latencies):.1f} ms ({args.compute_units})")
    print(f"report written to {report_path}")


if __name__ == "__main__":
    main()
