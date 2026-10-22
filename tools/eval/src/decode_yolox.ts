/**
 * YOLOX output decode: raw ONNX tensor to hold detections.
 *
 * The exported YOLOX graph runs the head decode in-graph
 * (head.decode_in_inference = True), so each of the 8400 anchors arrives as
 *
 *   [cx, cy, w, h, objectness, class_score, ...]
 *
 * with cx,cy,w,h in pixels of the 640x640 letterboxed frame, unclipped (values
 * routinely exceed the frame), and both scores already sigmoided. There is no
 * NMS in the graph, so this module converts to xyxy, clips to the frame, and
 * applies greedy class-agnostic NMS.
 *
 * The cxcywh reading was verified empirically on a val image: interpreting the
 * first four columns as cxcywh gives mean best IoU 0.79 against ground truth,
 * interpreting them as xyxy gives 0.00 (and yields negative widths).
 *
 * This module is YOLOX-specific. RF-DETR decoding lives in decode.ts.
 */

import type * as ort from "onnxruntime-node";

import { TARGET_SIZE } from "./preprocess.ts";

/**
 * NMS IoU and pre-NMS score floor, matching the YOLOX COCO evaluation
 * convention (nms 0.65, conf 0.01) so harness numbers line up with the
 * training-side validation numbers.
 */
export const YOLOX_NMS_IOU = 0.65;
export const YOLOX_PRE_NMS_FLOOR = 0.01;

export interface YoloxDecoded {
  /** xyxy boxes in pixels of the letterboxed frame, clipped to 0..size. */
  readonly boxes: Float32Array;
  /** objectness times the best class score, per anchor. */
  readonly scores: Float32Array;
  readonly numAnchors: number;
}

/** Convert YOLOX raw output (cxcywh pixels plus scores) into clipped xyxy boxes. */
export function decodeYoloxOutputs(
  results: Readonly<Record<string, ort.Tensor>>,
  size: number = TARGET_SIZE,
): YoloxDecoded {
  let data: ArrayLike<number> | undefined;
  let numAnchors = 0;
  let channels = 0;
  for (const value of Object.values(results)) {
    const dims = value.dims;
    if (dims.length === 3 && (dims[2] ?? 0) >= 6) {
      data = value.data as Float32Array;
      numAnchors = dims[1] ?? 0;
      channels = dims[2] ?? 0;
    }
  }
  if (data === undefined || numAnchors <= 0 || channels < 6) {
    throw new Error(
      `unexpected YOLOX outputs: ${Object.keys(results).join(", ")}; expected one [1, anchors, 6+] tensor`,
    );
  }

  const boxes = new Float32Array(numAnchors * 4);
  const scores = new Float32Array(numAnchors);
  const clamp = (value: number): number => Math.min(Math.max(value, 0), size);
  for (let anchor = 0; anchor < numAnchors; anchor += 1) {
    const base = anchor * channels;
    const cx = data[base] ?? 0;
    const cy = data[base + 1] ?? 0;
    const width = data[base + 2] ?? 0;
    const height = data[base + 3] ?? 0;
    const objectness = data[base + 4] ?? 0;
    let bestClass = 0;
    for (let channel = 5; channel < channels; channel += 1) {
      const value = data[base + channel] ?? 0;
      if (value > bestClass) {
        bestClass = value;
      }
    }
    boxes[anchor * 4] = clamp(cx - width / 2);
    boxes[anchor * 4 + 1] = clamp(cy - height / 2);
    boxes[anchor * 4 + 2] = clamp(cx + width / 2);
    boxes[anchor * 4 + 3] = clamp(cy + height / 2);
    scores[anchor] = objectness * bestClass;
  }
  return { boxes, scores, numAnchors };
}

/** Greedy class-agnostic NMS; returns kept box indices in descending score order. */
export function nmsIndices(
  boxes: ArrayLike<number>,
  scores: ArrayLike<number>,
  count: number,
  iouThreshold: number,
  scoreFloor = 0,
): number[] {
  const order: number[] = [];
  for (let index = 0; index < count; index += 1) {
    const score = scores[index] ?? 0;
    if (score > 0 && score >= scoreFloor) {
      order.push(index);
    }
  }
  order.sort((a, b) => (scores[b] ?? 0) - (scores[a] ?? 0));

  const suppressed = new Uint8Array(count);
  const kept: number[] = [];
  for (let position = 0; position < order.length; position += 1) {
    const index = order[position];
    if (index === undefined || suppressed[index] === 1) {
      continue;
    }
    kept.push(index);
    const ax1 = boxes[index * 4] ?? 0;
    const ay1 = boxes[index * 4 + 1] ?? 0;
    const ax2 = boxes[index * 4 + 2] ?? 0;
    const ay2 = boxes[index * 4 + 3] ?? 0;
    const areaA = Math.max(0, ax2 - ax1) * Math.max(0, ay2 - ay1);
    for (let next = position + 1; next < order.length; next += 1) {
      const other = order[next];
      if (other === undefined || suppressed[other] === 1) {
        continue;
      }
      const bx1 = boxes[other * 4] ?? 0;
      const by1 = boxes[other * 4 + 1] ?? 0;
      const bx2 = boxes[other * 4 + 2] ?? 0;
      const by2 = boxes[other * 4 + 3] ?? 0;
      const interWidth = Math.min(ax2, bx2) - Math.max(ax1, bx1);
      const interHeight = Math.min(ay2, by2) - Math.max(ay1, by1);
      if (interWidth <= 0 || interHeight <= 0) {
        continue;
      }
      const intersection = interWidth * interHeight;
      const areaB = Math.max(0, bx2 - bx1) * Math.max(0, by2 - by1);
      const union = areaA + areaB - intersection;
      const iou = union > 0 ? intersection / union : 0;
      if (iou > iouThreshold) {
        suppressed[other] = 1;
      }
    }
  }
  return kept;
}
