/**
 * End-to-end stub run: prove the eval harness is code-complete without a model.
 *
 * Generates a deterministic synthetic fixture (JPEGs + COCO JSON), runs the
 * full harness core (evaluateSplit) against a StubDetector in oracle mode and
 * asserts the metrics are exactly perfect (precision 1.0, recall 1.0, mAP@0.5
 * 1.0 at IoU 0.5 with jittered boxes), then against a noop stub and asserts
 * everything is zero. Writes a report clearly labeled as a STUB run; the
 * numbers validate the harness, not any model.
 *
 * Usage: node src/run_stub_eval.ts
 */

import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { StubDetector, type DetectorDetection } from "./detector.ts";
import { evaluateSplit } from "./evaluate.ts";
import { TARGET_SIZE, letterboxGeometryFor } from "./preprocess.ts";
import { writeFixture, type FixtureImage } from "./stub_fixture.ts";

const EVAL_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const FIXTURE_DIR = path.join(EVAL_ROOT, ".stub-fixture");
const REPORT_PATH = path.join(EVAL_ROOT, "reports", "stub_eval.json");

const IOU = 0.5;
const CONFIDENCE = 0.5;
const SCORE_FLOOR = 1e-4;
const JITTER_PX = 2;

/** Map fixture boxes (source pixels) into the letterboxed frame for the oracle stub. */
function oracleBoxesByFile(spec: readonly FixtureImage[]): Map<string, DetectorDetection[]> {
  const lookup = new Map<string, DetectorDetection[]>();
  for (const image of spec) {
    const { scale, padX, padY } = letterboxGeometryFor(image.width, image.height, TARGET_SIZE);
    lookup.set(
      path.basename(image.fileName),
      image.boxes.map((box) => {
        const x1 = box.x * scale + padX;
        const y1 = box.y * scale + padY;
        return { x1, y1, x2: x1 + box.width * scale, y2: y1 + box.height * scale, score: 0.9 };
      }),
    );
  }
  return lookup;
}

function assertEqual(actual: number, expected: number, what: string): void {
  if (actual !== expected) {
    throw new Error(`stub eval assertion failed: ${what} is ${actual}, expected ${expected}`);
  }
}

async function main(): Promise<void> {
  console.log(`writing stub fixture to ${FIXTURE_DIR}`);
  const spec = await writeFixture(FIXTURE_DIR);
  const totalBoxes = spec.reduce((sum, image) => sum + image.boxes.length, 0);
  console.log(`fixture: ${spec.length} images, ${totalBoxes} boxes`);

  console.log("running harness with oracle stub...");
  const oracle = new StubDetector({
    mode: "oracle",
    boxesByFile: oracleBoxesByFile(spec),
    jitterPx: JITTER_PX,
    score: 0.9,
  });
  const oracleResult = await evaluateSplit(oracle, FIXTURE_DIR, {
    iou: IOU,
    confidence: CONFIDENCE,
    scoreFloor: SCORE_FLOOR,
  });
  assertEqual(oracleResult.metrics.precision, 1, "oracle precision");
  assertEqual(oracleResult.metrics.recall, 1, "oracle recall");
  assertEqual(oracleResult.metrics.map05, 1, "oracle mAP@0.5");
  assertEqual(oracleResult.metrics.tp, totalBoxes, "oracle tp");
  assertEqual(oracleResult.metrics.fp, 0, "oracle fp");
  assertEqual(oracleResult.metrics.fn, 0, "oracle fn");

  console.log("running harness with noop stub...");
  const noop = new StubDetector({ mode: "noop" });
  const noopResult = await evaluateSplit(noop, FIXTURE_DIR, {
    iou: IOU,
    confidence: CONFIDENCE,
    scoreFloor: SCORE_FLOOR,
  });
  assertEqual(noopResult.metrics.precision, 0, "noop precision");
  assertEqual(noopResult.metrics.recall, 0, "noop recall");
  assertEqual(noopResult.metrics.map05, 0, "noop mAP@0.5");
  assertEqual(noopResult.metrics.tp, 0, "noop tp");
  assertEqual(noopResult.metrics.fp, 0, "noop fp");
  assertEqual(noopResult.metrics.fn, totalBoxes, "noop fn");

  const report = {
    report_id: "stub_eval",
    label: "STUB DETECTOR RUN, NOT A MODEL EVALUATION",
    description:
      "Harness code-complete proof: a deterministic synthetic fixture evaluated end to end through the real harness core (preprocess, matching, metrics, report writing) with a stub detector. Oracle metrics are exactly 1.0 and noop metrics are exactly 0.0. No model exists yet; these numbers validate the tooling only.",
    generated_at: new Date().toISOString(),
    detector: {
      oracle: {
        name: oracle.name,
        jitter_px: JITTER_PX,
        score: 0.9,
        note: "returns each ground truth box with deterministic sub-threshold jitter",
      },
      noop: { name: noop.name, note: "returns zero detections" },
    },
    fixture: {
      dir: path.relative(EVAL_ROOT, FIXTURE_DIR),
      images: spec.length,
      boxes: totalBoxes,
      note: "synthetic; generated deterministically, never used for training",
    },
    method: {
      preprocess: "letterbox 640x640 pad 114 centered, RGB float32 NCHW, (v/255 - mean)/std ImageNet",
      nms: "none (DETR-style set prediction, raw per-query outputs)",
      score_floor_for_map: SCORE_FLOOR,
      operating_confidence: CONFIDENCE,
      iou_threshold: IOU,
      map_definition: "single-class AP at IoU 0.5, VOC 2010+ all-point interpolation",
      matching: "greedy highest-IoU, confidence descending, one GT claimed once",
    },
    metrics: {
      oracle: oracleResult.metrics,
      noop: noopResult.metrics,
    },
    assertions: {
      oracle_perfect: true,
      noop_zero: true,
    },
    timing: {
      oracle_mean_inference_ms: Number(
        (oracleResult.inferenceMs.reduce((sum, value) => sum + value, 0) / Math.max(1, oracleResult.inferenceMs.length)).toFixed(3),
      ),
      note: "stub timings measure harness overhead only, not model inference",
    },
  };

  await mkdir(path.dirname(REPORT_PATH), { recursive: true });
  await writeFile(REPORT_PATH, `${JSON.stringify(report, null, 2)}\n`, "utf8");

  console.log("--- stub eval summary ---");
  console.log(`oracle: precision=${oracleResult.metrics.precision} recall=${oracleResult.metrics.recall} mAP@0.5=${oracleResult.metrics.map05}`);
  console.log(`noop:   precision=${noopResult.metrics.precision} recall=${noopResult.metrics.recall} mAP@0.5=${noopResult.metrics.map05}`);
  console.log(`report written to ${REPORT_PATH}`);
  console.log("run_stub_eval: OK (harness code-complete, stub numbers only)");
}

main().catch((error: unknown) => {
  console.error("run_stub_eval: FAILED", error);
  process.exitCode = 1;
});
