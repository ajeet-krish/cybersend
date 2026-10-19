/**
 * Hold detector eval harness (ONNX path).
 *
 * Runs the exported hold detector ONNX over a frozen COCO split with
 * onnxruntime-node and computes precision, recall, and mAP at IoU 0.5 for the
 * single "hold" class. Preprocessing is the shared pure-TS contract in
 * preprocess.ts (letterbox 640, pad 114, ImageNet normalization), and ground
 * truth boxes are mapped into the letterboxed frame, so raw-resolution test
 * images work directly. No NMS: RF-DETR is a DETR-style set predictor and is
 * evaluated on its raw per-query outputs.
 *
 * Usage:
 *   node src/eval_hold.ts [--model path.onnx] [--split-dir dir] [--report out.json]
 *                         [--confidence 0.5] [--iou 0.5] [--score-floor 1e-4]
 *                         [--gate] [--label text]
 *
 * --gate applies the Phase 4 quality gates from docs/requirements.md section 6
 * (precision >= 0.85, recall >= 0.80, mAP@0.5 >= 0.75) and exits with code 3
 * when any gate fails.
 */

import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { OnnxDetector } from "./detector.ts";
import { evaluateSplit } from "./evaluate.ts";

interface Args {
  readonly modelPath: string;
  readonly splitDir: string;
  readonly reportPath: string;
  readonly confidence: number;
  readonly iou: number;
  readonly scoreFloor: number;
  readonly gate: boolean;
  readonly label: string;
}

/** Phase 4 quality gates, docs/requirements.md section 6. */
export const PHASE4_GATES = { precisionMin: 0.85, recallMin: 0.8, map05Min: 0.75 } as const;

const EVAL_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const REPO_TOOLS = path.resolve(EVAL_ROOT, "..");
const DEFAULTS = {
  modelPath: path.join(REPO_TOOLS, "train", "artifacts", "holds_detector_d1.onnx"),
  splitDir: path.join(REPO_TOOLS, "train", "datasets", "merged", "test"),
  reportPath: path.join(EVAL_ROOT, "reports", "d1_test_eval.json"),
  confidence: 0.5,
  iou: 0.5,
  scoreFloor: 1e-4,
};

function parseArgs(argv: readonly string[]): Args {
  const readFlag = (name: string): string | undefined => {
    const index = argv.indexOf(name);
    return index >= 0 ? argv[index + 1] : undefined;
  };
  return {
    modelPath: path.resolve(readFlag("--model") ?? DEFAULTS.modelPath),
    splitDir: path.resolve(readFlag("--split-dir") ?? readFlag("--test-dir") ?? DEFAULTS.splitDir),
    reportPath: path.resolve(readFlag("--report") ?? DEFAULTS.reportPath),
    confidence: Number(readFlag("--confidence") ?? DEFAULTS.confidence),
    iou: Number(readFlag("--iou") ?? DEFAULTS.iou),
    scoreFloor: Number(readFlag("--score-floor") ?? DEFAULTS.scoreFloor),
    gate: argv.includes("--gate"),
    label: readFlag("--label") ?? "D1 BASELINE EVALUATION",
  };
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  console.log(`model: ${args.modelPath}`);
  console.log(`split: ${args.splitDir}`);
  console.log(
    `thresholds: confidence=${args.confidence} iou=${args.iou} score_floor=${args.scoreFloor} (no NMS, DETR-style raw queries)`,
  );

  const detector = await OnnxDetector.create(args.modelPath);
  const result = await evaluateSplit(detector, args.splitDir, {
    iou: args.iou,
    confidence: args.confidence,
    scoreFloor: args.scoreFloor,
  });

  const manifestPath = path.join(path.dirname(args.modelPath), "manifest.json");
  const manifestRaw = await readFile(manifestPath, "utf8").catch(() => null);
  const manifest = manifestRaw !== null ? (JSON.parse(manifestRaw) as Record<string, unknown>) : null;

  const gates = {
    precision: { value: result.metrics.precision, min: PHASE4_GATES.precisionMin },
    recall: { value: result.metrics.recall, min: PHASE4_GATES.recallMin },
    map_at_iou_0_5: { value: result.metrics.map05, min: PHASE4_GATES.map05Min },
  };
  const gatesPassed = Object.fromEntries(
    Object.entries(gates).map(([name, entry]) => [name, entry.value >= entry.min]),
  );
  const allGatesPassed = Object.values(gatesPassed).every(Boolean);

  const report = {
    report_id: "d1_eval",
    label: args.label,
    generated_at: new Date().toISOString(),
    model: {
      path: path.relative(path.dirname(args.reportPath), args.modelPath),
      manifest: manifest ?? undefined,
    },
    dataset: {
      split_dir: path.relative(path.dirname(args.reportPath), args.splitDir),
      images: result.images.length,
      ground_truth_instances: result.groundTruths.length,
      note: "see tools/train/DATASET_CARD.md for sources, licenses, and split provenance",
    },
    method: {
      preprocess: "letterbox 640x640 pad 114 centered, RGB float32 NCHW, (v/255 - mean)/std ImageNet",
      nms: "none (DETR-style set prediction, raw per-query outputs)",
      score_floor_for_map: args.scoreFloor,
      operating_confidence: args.confidence,
      iou_threshold: args.iou,
      map_definition: "single-class AP at IoU 0.5, VOC 2010+ all-point interpolation over confidence-ranked detections",
      matching: "greedy highest-IoU, confidence descending, one GT claimed once",
    },
    metrics: result.metrics,
    per_image: result.perImage,
    phase_4_gates: {
      note: "docs/requirements.md section 6. The operating threshold must be chosen on the val split, not test.",
      gates,
      passed: gatesPassed,
      all_passed: allGatesPassed,
    },
  };

  await mkdir(path.dirname(args.reportPath), { recursive: true });
  await writeFile(args.reportPath, `${JSON.stringify(report, null, 2)}\n`, "utf8");

  console.log("--- eval summary ---");
  console.log(`precision@IoU0.5 (conf>=${args.confidence}): ${result.metrics.precision.toFixed(4)}`);
  console.log(`recall@IoU0.5 (conf>=${args.confidence}):    ${result.metrics.recall.toFixed(4)}`);
  console.log(`mAP@0.5:                        ${result.metrics.map05.toFixed(4)}`);
  console.log(
    `tp=${result.metrics.tp} fp=${result.metrics.fp} fn=${result.metrics.fn} ` +
      `fp/image=${result.metrics.falsePositivesPerImage} ` +
      `median_abs_count_error=${result.metrics.medianAbsCountError}`,
  );
  console.log(`report written to ${args.reportPath}`);

  if (args.gate) {
    for (const [name, passed] of Object.entries(gatesPassed)) {
      const entry = gates[name as keyof typeof gates];
      console.log(`gate ${name}: ${entry.value} vs min ${entry.min} -> ${passed ? "PASS" : "FAIL"}`);
    }
    if (!allGatesPassed) {
      console.error("eval_hold: GATE FAILED");
      process.exitCode = 3;
    } else {
      console.log("eval_hold: all gates passed");
    }
  }
}

main().catch((error: unknown) => {
  console.error("eval_hold: FAILED", error);
  process.exitCode = 1;
});
