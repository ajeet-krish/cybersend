/**
 * Hold detector eval harness (ONNX path).
 *
 * Runs the exported hold detector ONNX over a frozen COCO split with
 * onnxruntime-node and computes precision, recall, and mAP at IoU 0.5 for the
 * single "hold" class. Preprocessing is the shared pure-TS contract in
 * preprocess.ts (letterbox 640, pad 114, centered); the tensor encoding follows
 * the model: ImageNet normalization for RF-DETR, raw 0..255 for YOLOX. The
 * merged dataset ships pre-letterboxed by hold-bake, so on that data the
 * letterbox is an identity and ground truth boxes already live in the model
 * frame.
 *
 * Postprocess differs by model. RF-DETR is a DETR-style set predictor and is
 * evaluated on its raw per-query outputs (no NMS). YOLOX has no NMS in its
 * graph, so the harness applies class-agnostic greedy NMS at IoU 0.65 over
 * anchors scoring at least 0.01, matching the training-side COCO evaluation.
 *
 * Usage:
 *   node src/eval_hold.ts [--model path.onnx] [--model-kind auto|rfdetr|yolox]
 *                         [--split-dir dir] [--report out.json]
 *                         [--confidence 0.5] [--iou 0.5] [--score-floor 1e-4]
 *                         [--gate] [--label text] [--i-accept-one-test-run]
 *
 * --model-kind defaults to auto, which reads the output names (dets plus labels
 * is RF-DETR, a single output is YOLOX) and refuses to guess when they match
 * neither.
 *
 * The default split is val (not test). Scoring the frozen test split requires
 * the explicit --i-accept-one-test-run flag and appends a line to
 * reports/test_ledger.jsonl (one gated test run policy, see README.md).
 *
 * --gate applies the Phase 4 quality gates from docs/requirements.md section 6
 * (precision >= 0.85, recall >= 0.80, mAP@0.5 >= 0.75) and exits with code 3
 * when any gate fails.
 */

import { appendFile, mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { OnnxDetector, type ModelKind } from "./detector.ts";
import { evaluateSplit } from "./evaluate.ts";
import {
  TEST_ACCEPT_FLAG,
  TEST_LEDGER_FILE,
  buildLedgerEntry,
  defaultReportName,
  formatLedgerEntry,
  gitDescribe,
  requireTestRunAcceptance,
  splitKind,
} from "./test_policy.ts";

interface Args {
  readonly modelPath: string;
  readonly modelKind: ModelKind | "auto";
  readonly splitDir: string;
  readonly reportPath: string;
  readonly confidence: number;
  readonly iou: number;
  readonly scoreFloor: number;
  readonly gate: boolean;
  readonly label: string;
  readonly acceptOneTestRun: boolean;
}

/** Phase 4 quality gates, docs/requirements.md section 6. */
export const PHASE4_GATES = { precisionMin: 0.85, recallMin: 0.8, map05Min: 0.75 } as const;

const EVAL_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const REPO_TOOLS = path.resolve(EVAL_ROOT, "..");
const REPO_ROOT = path.resolve(REPO_TOOLS, "..");
const DEFAULTS = {
  modelPath: path.join(REPO_TOOLS, "train", "artifacts", "holds_detector_d1.onnx"),
  splitDir: path.join(REPO_TOOLS, "train", "datasets", "merged", "val"),
  confidence: 0.5,
  iou: 0.5,
  scoreFloor: 1e-4,
};

function parseArgs(argv: readonly string[]): Args {
  const readFlag = (name: string): string | undefined => {
    const index = argv.indexOf(name);
    return index >= 0 ? argv[index + 1] : undefined;
  };
  const rawKind = readFlag("--model-kind") ?? "auto";
  if (rawKind !== "auto" && rawKind !== "rfdetr" && rawKind !== "yolox") {
    throw new Error(`--model-kind must be auto, rfdetr, or yolox (got ${rawKind})`);
  }
  const splitDir = path.resolve(
    readFlag("--split-dir") ?? readFlag("--test-dir") ?? DEFAULTS.splitDir,
  );
  return {
    modelPath: path.resolve(readFlag("--model") ?? DEFAULTS.modelPath),
    modelKind: rawKind,
    splitDir,
    reportPath: path.resolve(
      readFlag("--report") ?? path.join(EVAL_ROOT, "reports", defaultReportName(splitKind(splitDir))),
    ),
    confidence: Number(readFlag("--confidence") ?? DEFAULTS.confidence),
    iou: Number(readFlag("--iou") ?? DEFAULTS.iou),
    scoreFloor: Number(readFlag("--score-floor") ?? DEFAULTS.scoreFloor),
    gate: argv.includes("--gate"),
    label: readFlag("--label") ?? "D1 BASELINE EVALUATION",
    acceptOneTestRun: argv.includes(TEST_ACCEPT_FLAG),
  };
}

/** Read the export manifest that sits next to the ONNX file, either naming scheme. */
async function readManifest(modelPath: string): Promise<Record<string, unknown> | null> {
  const directory = path.dirname(modelPath);
  for (const name of ["manifest.json", "manifest_yolox_d1.json"]) {
    const raw = await readFile(path.join(directory, name), "utf8").catch(() => null);
    if (raw !== null) {
      return JSON.parse(raw) as Record<string, unknown>;
    }
  }
  return null;
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  const kind = splitKind(args.splitDir);

  // Fail fast: the frozen test split is guarded before any model or data loads.
  try {
    requireTestRunAcceptance(kind, args.acceptOneTestRun);
  } catch (error) {
    console.error(`eval_hold: ${(error as Error).message}`);
    process.exitCode = 2;
    return;
  }

  const manifest = await readManifest(args.modelPath);

  if (kind === "test") {
    // Append before scoring so a run that dies midway still consumed its
    // ledger line: every access to the frozen test split must be recorded.
    const ledgerPath = path.join(EVAL_ROOT, "reports", TEST_LEDGER_FILE);
    const entry = buildLedgerEntry({
      timestamp: new Date().toISOString(),
      model_id:
        typeof manifest?.id === "string" ? manifest.id : path.basename(args.modelPath, ".onnx"),
      model_path: path.relative(REPO_ROOT, args.modelPath),
      report_path: path.relative(REPO_ROOT, args.reportPath),
      split_dir: path.relative(REPO_ROOT, args.splitDir),
      git_describe: gitDescribe(REPO_ROOT),
      gate: args.gate,
      confidence: args.confidence,
    });
    await mkdir(path.dirname(ledgerPath), { recursive: true });
    await appendFile(ledgerPath, formatLedgerEntry(entry), "utf8");
    console.log(`test split: ledger entry appended to ${path.relative(REPO_ROOT, ledgerPath)}`);
  }

  const detector = await OnnxDetector.create(args.modelPath, args.modelKind);

  console.log(`model: ${args.modelPath}`);
  console.log(`model kind: ${detector.kind} (preprocess ${detector.preprocess})`);
  console.log(`split: ${args.splitDir}`);
  console.log(
    detector.kind === "yolox"
      ? `thresholds: confidence=${args.confidence} iou=${args.iou} score_floor=${args.scoreFloor} (NMS 0.65 over anchors >= 0.01)`
      : `thresholds: confidence=${args.confidence} iou=${args.iou} score_floor=${args.scoreFloor} (no NMS, DETR-style raw queries)`,
  );

  const result = await evaluateSplit(detector, args.splitDir, {
    iou: args.iou,
    confidence: args.confidence,
    scoreFloor: args.scoreFloor,
  });

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
      kind: detector.kind,
      preprocess: detector.preprocess,
      manifest: manifest ?? undefined,
    },
    dataset: {
      split_dir: path.relative(path.dirname(args.reportPath), args.splitDir),
      split_kind: kind,
      images: result.images.length,
      ground_truth_instances: result.groundTruths.length,
      note: "see tools/train/DATASET_CARD.md for sources, licenses, and split provenance",
    },
    method: {
      preprocess:
        detector.preprocess === "raw"
          ? "letterbox 640x640 pad 114 centered, RGB float32 NCHW, raw 0..255 (no normalization)"
          : "letterbox 640x640 pad 114 centered, RGB float32 NCHW, (v/255 - mean)/std ImageNet",
      nms:
        detector.kind === "yolox"
          ? "class-agnostic greedy NMS at IoU 0.65 over anchors scoring at least 0.01, applied in the harness (the graph has none)"
          : "none (DETR-style set prediction, raw per-query outputs)",
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
  console.log(`split kind: ${kind}`);
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
