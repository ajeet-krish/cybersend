/**
 * False positive anatomy for the hold detector eval harness.
 *
 * Runs the same detector and split as eval_hold.ts, then splits the operating
 * point false positives into structural buckets so a post-processing fix can be
 * judged on evidence instead of guesswork:
 *
 *   duplicate   a second box on a hold a higher-confidence box already claimed
 *               (overlap with a true positive box, or with a claimed ground truth,
 *               at IoU 0.5 or above)
 *   near miss   a box on a real hold whose overlap never reaches 0.5
 *   loose       best overlap with any ground truth is between 0.1 and 0.3
 *   background  no ground truth within IoU 0.1, so wall texture, volumes, or noise
 *
 * It also sweeps two deterministic post-processing knobs at the same operating
 * confidence, reporting the precision, recall, false positives per image, and
 * median count error each one would produce:
 *
 *   dedupe IoU  greedy per-image suppression of boxes overlapping a kept box
 *   area floor  drop boxes smaller than N square pixels in the 640 frame
 *
 * This script measures; it does not change the eval path. The sweeps say how
 * much of the false positive excess is reachable without another training run.
 *
 * Usage:
 *   node src/analyze_false_positives.ts [--model path.onnx] [--model-kind auto]
 *                                       [--split-dir dir] [--confidence 0.5]
 *                                       [--iou 0.5] [--report out.json]
 *                                       [--dump-fps out.json]
 *
 * --dump-fps writes every operating point false positive with its image name,
 * box, score, bucket, and overlaps, so the boxes can be cropped into a contact
 * sheet and inspected by eye. Most of the false positives land in "background"
 * or "near miss", and the difference between unlabelled real holds, wall
 * texture, volumes, and tape decides whether hard negatives can help at all.
 */

import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { OnnxDetector, type ModelKind } from "./detector.ts";
import { evaluateSplit } from "./evaluate.ts";
import { areaFilter, borderFilter, dedupe, operatingMetrics } from "./fp_filters.ts";
import { iou, matchDetections, type Detection, type GroundTruth } from "./metrics.ts";
import { TARGET_SIZE } from "./preprocess.ts";

const EVAL_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const REPO_TOOLS = path.resolve(EVAL_ROOT, "..");
const DEFAULTS = {
  modelPath: path.join(REPO_TOOLS, "train", "artifacts", "holds_detector_d1.onnx"),
  splitDir: path.join(REPO_TOOLS, "train", "datasets", "merged", "val"),
  confidence: 0.5,
  iou: 0.5,
};

interface Args {
  readonly modelPath: string;
  readonly modelKind: ModelKind | "auto";
  readonly splitDir: string;
  readonly reportPath: string;
  readonly confidence: number;
  readonly iou: number;
  readonly dumpFpsPath: string | null;
}

function parseArgs(argv: readonly string[]): Args {
  const readFlag = (name: string): string | undefined => {
    const index = argv.indexOf(name);
    return index >= 0 ? argv[index + 1] : undefined;
  };
  const rawKind = readFlag("--model-kind") ?? "auto";
  if (rawKind !== "auto" && rawKind !== "rfdetr" && rawKind !== "yolox") {
    throw new Error(`--model-kind must be auto, rfdetr, or yolox (got ${rawKind})`);
  }
  const splitDir = path.resolve(readFlag("--split-dir") ?? DEFAULTS.splitDir);
  return {
    modelPath: path.resolve(readFlag("--model") ?? DEFAULTS.modelPath),
    modelKind: rawKind,
    splitDir,
    reportPath: path.resolve(
      readFlag("--report") ?? path.join(EVAL_ROOT, "reports", "fp_analysis.json"),
    ),
    confidence: Number(readFlag("--confidence") ?? DEFAULTS.confidence),
    iou: Number(readFlag("--iou") ?? DEFAULTS.iou),
    dumpFpsPath: readFlag("--dump-fps") === undefined ? null : path.resolve(readFlag("--dump-fps") as string),
  };
}

function share(count: number, total: number): number {
  return Number((count / Math.max(1, total)).toFixed(4));
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));

  console.log(`model: ${args.modelPath}`);
  console.log(`split: ${args.splitDir}`);
  console.log(`operating confidence: ${args.confidence}, match IoU: ${args.iou}`);

  const detector = await OnnxDetector.create(args.modelPath, args.modelKind);
  console.log(`model kind: ${detector.kind} (preprocess ${detector.preprocess})`);

  const result = await evaluateSplit(detector, args.splitDir, {
    iou: args.iou,
    confidence: args.confidence,
    scoreFloor: 1e-4,
  });
  const imageCount = result.images.length;

  const all = result.detections; // sorted by score descending, floor applied
  const operating = all.filter((det) => det.score >= args.confidence);
  const groundTruths = result.groundTruths;

  const sorted = [...operating].sort((a, b) => b.score - a.score);
  const matches = matchDetections(sorted, groundTruths, args.iou, imageCount);
  const tpBoxesByImage = new Map<number, Detection[]>();
  const claimedGtByImage = new Map<number, GroundTruth[]>();
  const gtByImage = new Map<number, GroundTruth[]>();
  for (const gt of groundTruths) {
    const bucket = gtByImage.get(gt.imageIndex);
    if (bucket === undefined) {
      gtByImage.set(gt.imageIndex, [gt]);
    } else {
      bucket.push(gt);
    }
  }
  for (const pair of matches.pairs) {
    const det = sorted[pair.detectionIndex];
    const gt = (gtByImage.get(pair.imageIndex) ?? [])[pair.gtIndex];
    if (det !== undefined) {
      const bucket = tpBoxesByImage.get(pair.imageIndex);
      if (bucket === undefined) {
        tpBoxesByImage.set(pair.imageIndex, [det]);
      } else {
        bucket.push(det);
      }
    }
    if (gt !== undefined) {
      const bucket = claimedGtByImage.get(pair.imageIndex);
      if (bucket === undefined) {
        claimedGtByImage.set(pair.imageIndex, [gt]);
      } else {
        bucket.push(gt);
      }
    }
  }

  const fpDetections = sorted.filter((_, index) => matches.tpFlags[index] !== true);
  const fpRecords: Array<Record<string, unknown>> = [];

  const buckets = { duplicate: 0, near_miss: 0, loose: 0, background: 0 };
  const byScoreBand = new Map<string, number>();
  const byAreaBand = new Map<string, number>();
  const perImageFp = new Map<number, number>();
  let areaSum = 0;
  let sideSum = 0;

  for (const det of fpDetections) {
    const claimed = claimedGtByImage.get(det.imageIndex) ?? [];
    const allGt = gtByImage.get(det.imageIndex) ?? [];
    const tpBoxes = tpBoxesByImage.get(det.imageIndex) ?? [];

    const overlapTp = tpBoxes.reduce((best, box) => Math.max(best, iou(det, box)), 0);
    const overlapClaimed = claimed.reduce((best, gt) => Math.max(best, iou(det, gt)), 0);
    const overlapAnyGt = allGt.reduce((best, gt) => Math.max(best, iou(det, gt)), 0);

    let bucket: string;
    if (overlapTp >= 0.5 || overlapClaimed >= 0.5) {
      buckets.duplicate += 1;
      bucket = "duplicate";
    } else if (overlapAnyGt >= 0.3) {
      buckets.near_miss += 1;
      bucket = "near_miss";
    } else if (overlapAnyGt >= 0.1) {
      buckets.loose += 1;
      bucket = "loose";
    } else {
      buckets.background += 1;
      bucket = "background";
    }
    fpRecords.push({
      file_name: result.images[det.imageIndex]?.file_name ?? String(det.imageIndex),
      image_index: det.imageIndex,
      score: Number(det.score.toFixed(4)),
      x1: Number(det.x1.toFixed(1)),
      y1: Number(det.y1.toFixed(1)),
      x2: Number(det.x2.toFixed(1)),
      y2: Number(det.y2.toFixed(1)),
      bucket,
      best_iou_any_gt: Number(overlapAnyGt.toFixed(3)),
      best_iou_tp_box: Number(overlapTp.toFixed(3)),
      best_iou_claimed_gt: Number(overlapClaimed.toFixed(3)),
    });

    const bandLow = Math.floor(det.score * 10) / 10;
    const band = `${bandLow.toFixed(1)}-${(bandLow + 0.1).toFixed(1)}`;
    byScoreBand.set(band, (byScoreBand.get(band) ?? 0) + 1);

    const area = Math.max(0, det.x2 - det.x1) * Math.max(0, det.y2 - det.y1);
    areaSum += area;
    sideSum += Math.sqrt(area);
    const areaBand =
      area < 100 ? "area < 100 px2" : area < 400 ? "area 100-400 px2" : area < 1600 ? "area 400-1600 px2" : area < 6400 ? "area 1600-6400 px2" : "area >= 6400 px2";
    byAreaBand.set(areaBand, (byAreaBand.get(areaBand) ?? 0) + 1);

    perImageFp.set(det.imageIndex, (perImageFp.get(det.imageIndex) ?? 0) + 1);
  }

  const base = operatingMetrics(operating, groundTruths, imageCount, args.iou);

  const dedupeSweep = [0.3, 0.4, 0.5, 0.6, 0.65, 0.7].map((threshold) => ({
    iou: threshold,
    ...operatingMetrics(dedupe(operating, threshold), groundTruths, imageCount, args.iou),
  }));

  const areaSweep = [9, 25, 49, 100, 196, 400].map((minArea) => ({
    min_area_px2: minArea,
    ...operatingMetrics(areaFilter(operating, minArea), groundTruths, imageCount, args.iou),
  }));

  const borderSweep = [0, 2, 8, 16].map((margin) => ({
    margin_px: margin,
    ...operatingMetrics(borderFilter(operating, margin), groundTruths, imageCount, args.iou),
  }));

  const borderTouching = fpDetections.filter(
    (det) =>
      det.x1 <= 2 || det.y1 <= 2 || det.x2 >= TARGET_SIZE - 2 || det.y2 >= TARGET_SIZE - 2,
  ).length;

  const combinedSweep = [0.4, 0.5, 0.6].flatMap((threshold) =>
    [25, 49, 100].map((minArea) => ({
      iou: threshold,
      min_area_px2: minArea,
      ...operatingMetrics(
        areaFilter(dedupe(operating, threshold), minArea),
        groundTruths,
        imageCount,
        args.iou,
      ),
    })),
  );

  const worstImages = [...perImageFp.entries()]
    .sort((a, b) => b[1] - a[1])
    .slice(0, 10)
    .map(([imageIndex, count]) => ({
      file_name: result.images[imageIndex]?.file_name ?? String(imageIndex),
      false_positives: count,
      gt: (gtByImage.get(imageIndex) ?? []).length,
    }));

  const report = {
    generated_at: new Date().toISOString(),
    model: args.modelPath,
    model_kind: detector.kind,
    split_dir: args.splitDir,
    images: imageCount,
    ground_truths: groundTruths.length,
    operating_confidence: args.confidence,
    match_iou: args.iou,
    baseline: base,
    false_positive_anatomy: {
      total: fpDetections.length,
      duplicate: { count: buckets.duplicate, share: share(buckets.duplicate, fpDetections.length) },
      near_miss: { count: buckets.near_miss, share: share(buckets.near_miss, fpDetections.length) },
      loose: { count: buckets.loose, share: share(buckets.loose, fpDetections.length) },
      background: { count: buckets.background, share: share(buckets.background, fpDetections.length) },
      mean_area_px2: Number((areaSum / Math.max(1, fpDetections.length)).toFixed(1)),
      median_equivalent_side_px: Number((sideSum / Math.max(1, fpDetections.length)).toFixed(1)),
      by_score_band: Object.fromEntries([...byScoreBand.entries()].sort()),
      by_area_band: Object.fromEntries([...byAreaBand.entries()]),
    },
    border: {
      false_positives_touching_edge: borderTouching,
      share: share(borderTouching, fpDetections.length),
      sweep: borderSweep,
    },
    dedupe_sweep: dedupeSweep,
    area_sweep: areaSweep,
    combined_sweep: combinedSweep,
    worst_images: worstImages,
  };

  await mkdir(path.dirname(args.reportPath), { recursive: true });
  await writeFile(args.reportPath, `${JSON.stringify(report, null, 2)}\n`, "utf8");

  if (args.dumpFpsPath !== null) {
    await mkdir(path.dirname(args.dumpFpsPath), { recursive: true });
    await writeFile(
      args.dumpFpsPath,
      `${JSON.stringify({ model: args.modelPath, operating_confidence: args.confidence, false_positives: fpRecords }, null, 2)}\n`,
      "utf8",
    );
    console.log(`false positive boxes written to ${args.dumpFpsPath}`);
  }

  console.log("--- baseline ---");
  console.log(
    `precision=${base.precision} recall=${base.recall} fp=${base.fp} fp/image=${base.fpPerImage} count_err=${base.medianAbsCountError}`,
  );
  console.log("--- false positive anatomy ---");
  console.log(
    `total=${fpDetections.length} duplicate=${buckets.duplicate} (${(share(buckets.duplicate, fpDetections.length) * 100).toFixed(1)}%) ` +
      `near_miss=${buckets.near_miss} (${(share(buckets.near_miss, fpDetections.length) * 100).toFixed(1)}%) ` +
      `loose=${buckets.loose} (${(share(buckets.loose, fpDetections.length) * 100).toFixed(1)}%) ` +
      `background=${buckets.background} (${(share(buckets.background, fpDetections.length) * 100).toFixed(1)}%)`,
  );
  console.log(`by score band: ${JSON.stringify(Object.fromEntries([...byScoreBand.entries()].sort()))}`);
  console.log(`by area band: ${JSON.stringify(Object.fromEntries(byAreaBand))}`);
  console.log(
    `false positives touching the frame edge (2 px): ${borderTouching} (${(share(borderTouching, fpDetections.length) * 100).toFixed(1)}%)`,
  );
  console.log("--- border filter sweep ---");
  for (const row of borderSweep) {
    console.log(
      `margin=${row.margin_px}: precision=${row.precision} recall=${row.recall} fp/image=${row.fpPerImage} count_err=${row.medianAbsCountError}`,
    );
  }
  console.log("--- dedupe sweep ---");
  for (const row of dedupeSweep) {
    console.log(
      `iou=${row.iou}: precision=${row.precision} recall=${row.recall} fp/image=${row.fpPerImage} count_err=${row.medianAbsCountError}`,
    );
  }
  console.log("--- area floor sweep ---");
  for (const row of areaSweep) {
    console.log(
      `min_area=${row.min_area_px2}: precision=${row.precision} recall=${row.recall} fp/image=${row.fpPerImage} count_err=${row.medianAbsCountError}`,
    );
  }
  console.log("--- combined sweep (dedupe then area floor) ---");
  for (const row of combinedSweep) {
    console.log(
      `iou=${row.iou} min_area=${row.min_area_px2}: precision=${row.precision} recall=${row.recall} fp/image=${row.fpPerImage} count_err=${row.medianAbsCountError}`,
    );
  }
  console.log(`report written to ${args.reportPath}`);
}

main().catch((error: unknown) => {
  console.error("analyze_false_positives: FAILED", error);
  process.exitCode = 1;
});
