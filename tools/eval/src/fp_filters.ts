/**
 * Pure post-processing filters for the false positive analysis.
 *
 * These are the deterministic knobs a shipped app could apply without another
 * training run: duplicate suppression, a minimum box area, and an edge filter
 * for holds clipped by the photo boundary. analyze_false_positives.ts sweeps
 * them; this module keeps them testable without loading a model or touching
 * disk.
 */

import { iou, matchDetections, median, type Detection, type GroundTruth } from "./metrics.ts";
import { TARGET_SIZE } from "./preprocess.ts";

export interface OperatingMetrics {
  readonly tp: number;
  readonly fp: number;
  readonly fn: number;
  readonly precision: number;
  readonly recall: number;
  readonly fpPerImage: number;
  readonly medianAbsCountError: number;
}

/** Operating point metrics for a detection list, same convention as evaluateSplit. */
export function operatingMetrics(
  detections: readonly Detection[],
  groundTruths: readonly GroundTruth[],
  imageCount: number,
  iouThreshold: number,
): OperatingMetrics {
  const sorted = [...detections].sort((a, b) => b.score - a.score);
  const matches = matchDetections(sorted, groundTruths, iouThreshold, imageCount);
  const tpPerImage = new Map<number, number>();
  for (const pair of matches.pairs) {
    tpPerImage.set(pair.imageIndex, (tpPerImage.get(pair.imageIndex) ?? 0) + 1);
  }
  const gtPerImage = new Map<number, number>();
  for (const gt of groundTruths) {
    gtPerImage.set(gt.imageIndex, (gtPerImage.get(gt.imageIndex) ?? 0) + 1);
  }
  const detPerImage = new Map<number, number>();
  for (const det of sorted) {
    detPerImage.set(det.imageIndex, (detPerImage.get(det.imageIndex) ?? 0) + 1);
  }
  const countErrors: number[] = [];
  for (let imageIndex = 0; imageIndex < imageCount; imageIndex += 1) {
    countErrors.push(
      Math.abs((detPerImage.get(imageIndex) ?? 0) - (gtPerImage.get(imageIndex) ?? 0)),
    );
  }
  const tp = matches.tpCount;
  const fp = matches.fpCount;
  return {
    tp,
    fp,
    fn: groundTruths.length - tp,
    precision: Number((tp / Math.max(1, tp + fp)).toFixed(4)),
    recall: Number((tp / Math.max(1, groundTruths.length)).toFixed(4)),
    fpPerImage: Number((fp / Math.max(1, imageCount)).toFixed(4)),
    medianAbsCountError: Number(median(countErrors).toFixed(2)),
  };
}

/** Greedy per-image duplicate suppression at the given IoU, highest score wins. */
export function dedupe(detections: readonly Detection[], iouThreshold: number): Detection[] {
  const byImage = new Map<number, Detection[]>();
  for (const det of detections) {
    const bucket = byImage.get(det.imageIndex);
    if (bucket === undefined) {
      byImage.set(det.imageIndex, [det]);
    } else {
      bucket.push(det);
    }
  }
  const kept: Detection[] = [];
  for (const bucket of byImage.values()) {
    bucket.sort((a, b) => b.score - a.score);
    const accepted: Detection[] = [];
    for (const det of bucket) {
      if (accepted.every((other) => iou(det, other) < iouThreshold)) {
        accepted.push(det);
      }
    }
    kept.push(...accepted);
  }
  return kept;
}

/** Drop boxes whose area in the model frame is below the floor. */
export function areaFilter(detections: readonly Detection[], minArea: number): Detection[] {
  return detections.filter((det) => {
    const width = Math.max(0, det.x2 - det.x1);
    const height = Math.max(0, det.y2 - det.y1);
    return width * height >= minArea;
  });
}

/**
 * Drop boxes clipped by the frame edge. A hold cut off by the photo boundary
 * carries no usable position, and annotators conventionally skip truncated
 * holds, so counting those boxes as false positives measures the annotation
 * convention rather than the model.
 */
export function borderFilter(detections: readonly Detection[], margin: number): Detection[] {
  return detections.filter(
    (det) =>
      det.x1 > margin &&
      det.y1 > margin &&
      det.x2 < TARGET_SIZE - margin &&
      det.y2 < TARGET_SIZE - margin,
  );
}
