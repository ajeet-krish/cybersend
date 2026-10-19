/**
 * Pure detection metrics for the hold detector eval harness.
 *
 * Single class ("hold"). Matching is the standard greedy scheme: detections pooled
 * across images, sorted by confidence descending, each matched to the unmatched ground
 * truth with the highest IoU in the same image at or above the IoU threshold.
 * mAP@0.5 uses the VOC 2010+ all-point interpolated precision envelope (step integral).
 */

export interface Detection {
  readonly imageIndex: number;
  readonly score: number;
  readonly x1: number;
  readonly y1: number;
  readonly x2: number;
  readonly y2: number;
}

export interface GroundTruth {
  readonly imageIndex: number;
  readonly x1: number;
  readonly y1: number;
  readonly x2: number;
  readonly y2: number;
}

export interface MatchPair {
  readonly detectionIndex: number;
  readonly gtIndex: number;
  readonly imageIndex: number;
  readonly iou: number;
}

export interface MatchResult {
  readonly tpFlags: boolean[];
  readonly pairs: MatchPair[];
  readonly tpCount: number;
  readonly fpCount: number;
}

/** Intersection over union of two xyxy boxes. Zero area yields 0. */
export function iou(a: Detection | GroundTruth, b: Detection | GroundTruth): number {
  const ix1 = Math.max(a.x1, b.x1);
  const iy1 = Math.max(a.y1, b.y1);
  const ix2 = Math.min(a.x2, b.x2);
  const iy2 = Math.min(a.y2, b.y2);
  const inter = Math.max(0, ix2 - ix1) * Math.max(0, iy2 - iy1);
  if (inter <= 0) {
    return 0;
  }
  const areaA = Math.max(0, a.x2 - a.x1) * Math.max(0, a.y2 - a.y1);
  const areaB = Math.max(0, b.x2 - b.x1) * Math.max(0, b.y2 - b.y1);
  const union = areaA + areaB - inter;
  return union > 0 ? inter / union : 0;
}

/**
 * Greedy confidence-ordered matching of pooled detections against ground truth.
 * tpFlags[i] corresponds to sortedDetections[i]; a detection matched to a ground truth
 * already claimed by a higher-confidence detection counts as a false positive.
 */
export function matchDetections(
  sortedDetections: readonly Detection[],
  groundTruths: readonly GroundTruth[],
  iouThreshold: number,
  imageCount: number,
): MatchResult {
  const gtByImage: GroundTruth[][] = Array.from({ length: imageCount }, () => []);
  for (const gt of groundTruths) {
    gtByImage[gt.imageIndex]?.push(gt);
  }
  const claimed: boolean[][] = gtByImage.map((list) => list.map(() => false));

  const tpFlags: boolean[] = [];
  const pairs: MatchPair[] = [];
  for (const [detectionIndex, det] of sortedDetections.entries()) {
    const candidates = gtByImage[det.imageIndex] ?? [];
    const claimedRow = claimed[det.imageIndex];
    let bestIndex = -1;
    let bestIou = iouThreshold;
    for (let index = 0; index < candidates.length; index += 1) {
      if (claimedRow?.[index] === true) {
        continue;
      }
      const overlap = iou(det, candidates[index] as GroundTruth);
      if (overlap >= bestIou) {
        bestIou = overlap;
        bestIndex = index;
      }
    }
    if (bestIndex >= 0 && claimedRow !== undefined) {
      claimedRow[bestIndex] = true;
      pairs.push({ detectionIndex, gtIndex: bestIndex, imageIndex: det.imageIndex, iou: bestIou });
      tpFlags.push(true);
    } else {
      tpFlags.push(false);
    }
  }

  const tpCount = pairs.length;
  return { tpFlags, pairs, tpCount, fpCount: sortedDetections.length - tpCount };
}

/** Mean average precision at IoU 0.5 from confidence-ranked TP/FP flags (VOC 2010+ AP). */
export function averagePrecision(tpFlags: readonly boolean[], totalGroundTruths: number): number {
  if (totalGroundTruths === 0 || tpFlags.length === 0) {
    return 0;
  }
  const precisions: number[] = [];
  const recalls: number[] = [];
  let tp = 0;
  let fp = 0;
  for (const isTp of tpFlags) {
    if (isTp) {
      tp += 1;
    } else {
      fp += 1;
    }
    precisions.push(tp / (tp + fp));
    recalls.push(tp / totalGroundTruths);
  }

  // VOC 2010+ all-point interpolation: the precision envelope pe(r) at each
  // recall level r is the maximum precision reached at any recall >= r, and
  // AP is the step integral of pe over recall. The suffix maximum array holds
  // exactly that envelope per ranked position.
  const suffixMax: number[] = [];
  let running = 0;
  for (let index = precisions.length - 1; index >= 0; index -= 1) {
    running = Math.max(running, precisions[index] ?? 0);
    suffixMax[index] = running;
  }
  let ap = 0;
  let previousRecall = 0;
  for (let index = 0; index < precisions.length; index += 1) {
    const recall = recalls[index] ?? 0;
    if (recall > previousRecall) {
      ap += (recall - previousRecall) * (suffixMax[index] ?? 0);
      previousRecall = recall;
    }
  }
  return ap;
}

/** Median of a numeric array; returns 0 for an empty array. */
export function median(values: readonly number[]): number {
  if (values.length === 0) {
    return 0;
  }
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  if (sorted.length % 2 === 1) {
    return sorted[middle] ?? 0;
  }
  return ((sorted[middle - 1] ?? 0) + (sorted[middle] ?? 0)) / 2;
}

/** Mean of a numeric array; returns 0 for an empty array. */
export function mean(values: readonly number[]): number {
  if (values.length === 0) {
    return 0;
  }
  let total = 0;
  for (const value of values) {
    total += value;
  }
  return total / values.length;
}
