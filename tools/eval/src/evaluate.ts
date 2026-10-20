/**
 * Detector-agnostic eval core: run any Detector over a COCO split and compute
 * single-class detection metrics at IoU 0.5.
 *
 * Ground truth boxes are stored in image pixels (xywh) and are mapped into the
 * letterboxed frame with the same preprocess contract the model sees
 * (letterbox 640, pad 114, centered). The merged D1 dataset ships pre-letterboxed
 * by tools/train hold-bake, so on that data the meta is scale 1 with zero pads
 * and the mapping below is an exact identity; raw-resolution splits (fixtures,
 * own-gym photos) are letterboxed here instead. Matching is greedy
 * confidence-ordered; mAP uses VOC 2010+ all-point interpolation (see
 * metrics.ts).
 */

import { readFile } from "node:fs/promises";
import path from "node:path";

import { decode as decodeJpeg } from "jpeg-js";

import type { Detector, DetectorDetection } from "./detector.ts";
import { averagePrecision, matchDetections, mean, median, type Detection, type GroundTruth } from "./metrics.ts";
import { letterboxToTensor, TARGET_SIZE } from "./preprocess.ts";

export interface CocoImage {
  readonly id: number;
  readonly file_name: string;
  readonly width: number;
  readonly height: number;
}

export interface CocoAnnotation {
  readonly image_id: number;
  readonly bbox: readonly [number, number, number, number];
}

export interface CocoFile {
  readonly images: CocoImage[];
  readonly annotations: CocoAnnotation[];
  readonly categories?: Array<{ readonly id: number; readonly name: string }>;
}

export interface EvalOptions {
  readonly iou: number;
  readonly confidence: number;
  readonly scoreFloor: number;
}

export interface PerImageRow {
  readonly file_name: string;
  readonly gt: number;
  readonly detections: number;
  readonly tp: number;
  readonly fp: number;
  readonly fn: number;
  readonly inference_ms: number;
}

export interface EvalResult {
  readonly images: CocoImage[];
  readonly groundTruths: GroundTruth[];
  readonly detections: Detection[];
  readonly inferenceMs: number[];
  readonly perImage: PerImageRow[];
  readonly metrics: {
    readonly precision: number;
    readonly recall: number;
    readonly map05: number;
    readonly tp: number;
    readonly fp: number;
    readonly fn: number;
    readonly falsePositivesPerImage: number;
    readonly meanCenterErrorPx: number;
    readonly medianCenterErrorPx: number;
    readonly medianAbsCountError: number;
    readonly detectionsAboveScoreFloor: number;
  };
}

/** Map a source-pixel xywh box into the letterboxed frame as xyxy pixels. */
export function gtBoxToLetterbox(
  bbox: readonly [number, number, number, number],
  scale: number,
  padX: number,
  padY: number,
): { x1: number; y1: number; x2: number; y2: number } {
  const [x, y, boxWidth, boxHeight] = bbox;
  const x1 = x * scale + padX;
  const y1 = y * scale + padY;
  return { x1, y1, x2: x1 + boxWidth * scale, y2: y1 + boxHeight * scale };
}

async function loadSplit(splitDir: string): Promise<{ coco: CocoFile; gtByImage: GroundTruth[][] }> {
  const coco = JSON.parse(await readFile(path.join(splitDir, "_annotations.coco.json"), "utf8")) as unknown as CocoFile;
  const gtByImage: GroundTruth[][] = coco.images.map(() => []);
  const indexById = new Map<number, number>(coco.images.map((image, index) => [image.id, index]));
  for (const annotation of coco.annotations) {
    const imageIndex = indexById.get(annotation.image_id);
    if (imageIndex === undefined) {
      continue;
    }
    const [x, y, boxWidth, boxHeight] = annotation.bbox;
    gtByImage[imageIndex]?.push({ imageIndex, x1: x, y1: y, x2: x + boxWidth, y2: y + boxHeight });
  }
  return { coco, gtByImage };
}

/** Run a detector over a COCO split directory and compute the metrics. */
export async function evaluateSplit(
  detector: Detector,
  splitDir: string,
  options: EvalOptions,
): Promise<EvalResult> {
  const { coco, gtByImage: gtSourceByImage } = await loadSplit(splitDir);

  const detections: Detection[] = [];
  const inferenceMs: number[] = [];
  const perImage: PerImageRow[] = [];
  // Ground truth mapped into the letterboxed frame, the frame both detections
  // and metrics live in. With the hold-bake dataset the meta is scale 1 and
  // zero pads, so this mapping is an identity and the boxes below are already
  // in model pixels; the transform stays for unbaked (raw-resolution) splits.
  const gtByImage: GroundTruth[][] = coco.images.map(() => []);

  for (const [imageIndex, image] of coco.images.entries()) {
    const jpegBytes = await readFile(path.join(splitDir, image.file_name));
    const decoded = decodeJpeg(jpegBytes, { useTArray: true, maxMemoryUsageInMB: 1024 });
    if (decoded.width !== image.width || decoded.height !== image.height) {
      throw new Error(
        `${image.file_name}: JPEG is ${decoded.width}x${decoded.height} but the annotation file says ${image.width}x${image.height}`,
      );
    }
    const { data, meta } = letterboxToTensor(decoded.data, decoded.width, decoded.height, TARGET_SIZE);

    const letterboxed: GroundTruth[] = (gtSourceByImage[imageIndex] ?? []).map((gt) => {
      const box = gtBoxToLetterbox(
        [gt.x1, gt.y1, gt.x2 - gt.x1, gt.y2 - gt.y1],
        meta.scale,
        meta.padX,
        meta.padY,
      );
      return { imageIndex, ...box };
    });
    gtByImage[imageIndex] = letterboxed;

    const start = performance.now();
    const raw = await detector.detect(data, { fileName: path.basename(image.file_name) });
    inferenceMs.push(performance.now() - start);

    let countAboveFloor = 0;
    for (const det of raw) {
      if (det.score < options.scoreFloor) {
        continue;
      }
      countAboveFloor += 1;
      detections.push({ imageIndex, score: det.score, ...toXyxy(det) });
    }
    perImage.push({
      file_name: image.file_name,
      gt: letterboxed.length,
      detections: countAboveFloor,
      tp: 0,
      fp: 0,
      fn: 0,
      inference_ms: inferenceMs[inferenceMs.length - 1] ?? 0,
    });
    console.log(
      `image ${imageIndex + 1}/${coco.images.length} ${path.basename(image.file_name)}: ` +
        `gt=${letterboxed.length} dets_above_floor=${countAboveFloor} ` +
        `infer=${(inferenceMs[inferenceMs.length - 1] ?? 0).toFixed(1)}ms (scale=${meta.scale.toFixed(4)})`,
    );
  }

  const groundTruths = gtByImage.flat();

  // mAP@0.5 over every detection above the score floor, confidence ranked.
  const sortedAll = [...detections].sort((a, b) => b.score - a.score);
  const allMatches = matchDetections(sortedAll, groundTruths, options.iou, coco.images.length);
  const map05 = averagePrecision(allMatches.tpFlags, groundTruths.length);

  // Operating point metrics at the declared confidence threshold.
  const sortedOperating = sortedAll.filter((det) => det.score >= options.confidence);
  const operatingMatches = matchDetections(sortedOperating, groundTruths, options.iou, coco.images.length);
  const precision = operatingMatches.tpCount / Math.max(1, operatingMatches.tpCount + operatingMatches.fpCount);
  const recall = operatingMatches.tpCount / Math.max(1, groundTruths.length);

  const gtByImageForPairs: GroundTruth[][] = coco.images.map(() => []);
  for (const gt of groundTruths) {
    gtByImageForPairs[gt.imageIndex]?.push(gt);
  }
  const centerErrorsPx: number[] = [];
  for (const pair of operatingMatches.pairs) {
    const det = sortedOperating[pair.detectionIndex];
    const gt = gtByImageForPairs[pair.imageIndex]?.[pair.gtIndex];
    if (det === undefined || gt === undefined) {
      continue;
    }
    centerErrorsPx.push(
      Math.hypot((det.x1 + det.x2) / 2 - (gt.x1 + gt.x2) / 2, (det.y1 + det.y2) / 2 - (gt.y1 + gt.y2) / 2),
    );
  }

  const tpPerImage = new Map<number, number>();
  for (const pair of operatingMatches.pairs) {
    tpPerImage.set(pair.imageIndex, (tpPerImage.get(pair.imageIndex) ?? 0) + 1);
  }
  const countErrors: number[] = [];
  for (const imageIndex of coco.images.keys()) {
    const gtCount = gtByImage[imageIndex]?.length ?? 0;
    const detCount = sortedOperating.filter((det) => det.imageIndex === imageIndex).length;
    const tpCount = tpPerImage.get(imageIndex) ?? 0;
    const row = perImage[imageIndex];
    if (row !== undefined) {
      perImage[imageIndex] = { ...row, tp: tpCount, fp: detCount - tpCount, fn: gtCount - tpCount };
    }
    countErrors.push(detCount - gtCount);
  }

  return {
    images: coco.images,
    groundTruths,
    detections: sortedAll,
    inferenceMs,
    perImage,
    metrics: {
      precision: Number(precision.toFixed(4)),
      recall: Number(recall.toFixed(4)),
      map05: Number(map05.toFixed(4)),
      tp: operatingMatches.tpCount,
      fp: operatingMatches.fpCount,
      fn: groundTruths.length - operatingMatches.tpCount,
      falsePositivesPerImage: Number(
        (operatingMatches.fpCount / Math.max(1, coco.images.length)).toFixed(4),
      ),
      meanCenterErrorPx: Number(mean(centerErrorsPx).toFixed(2)),
      medianCenterErrorPx: Number(median(centerErrorsPx).toFixed(2)),
      medianAbsCountError: Number(median(countErrors.map(Math.abs)).toFixed(2)),
      detectionsAboveScoreFloor: sortedAll.length,
    },
  };
}

function toXyxy(det: DetectorDetection): Pick<Detection, "x1" | "y1" | "x2" | "y2"> {
  return { x1: det.x1, y1: det.y1, x2: det.x2, y2: det.y2 };
}
