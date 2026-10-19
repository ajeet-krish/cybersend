/**
 * End-to-end harness test against the stub detector (no model, no ONNX).
 *
 * Generates the deterministic synthetic fixture in a temporary directory and
 * runs the real harness core (evaluateSplit: decode, preprocess, matching,
 * metrics) with the oracle and noop stubs. This is the unit test proving the
 * harness is code-complete before any D1 model exists.
 */

import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";

import { StubDetector, type DetectorDetection } from "./detector.ts";
import { evaluateSplit } from "./evaluate.ts";
import { TARGET_SIZE, letterboxGeometryFor } from "./preprocess.ts";
import { writeFixture, type FixtureImage } from "./stub_fixture.ts";

const IOU = 0.5;
const CONFIDENCE = 0.5;
const SCORE_FLOOR = 1e-4;

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

test("harness end to end with oracle stub yields perfect metrics", async () => {
  const dir = await mkdtemp(path.join(tmpdir(), "cybersend-stub-eval-"));
  try {
    const spec = await writeFixture(dir);
    const totalBoxes = spec.reduce((sum, image) => sum + image.boxes.length, 0);
    assert.ok(totalBoxes >= 12, `fixture should carry a meaningful box count, got ${totalBoxes}`);

    const oracle = new StubDetector({
      mode: "oracle",
      boxesByFile: oracleBoxesByFile(spec),
      jitterPx: 2,
      score: 0.9,
    });
    const result = await evaluateSplit(oracle, dir, {
      iou: IOU,
      confidence: CONFIDENCE,
      scoreFloor: SCORE_FLOOR,
    });
    assert.equal(result.metrics.precision, 1);
    assert.equal(result.metrics.recall, 1);
    assert.equal(result.metrics.map05, 1);
    assert.equal(result.metrics.tp, totalBoxes);
    assert.equal(result.metrics.fp, 0);
    assert.equal(result.metrics.fn, 0);
    assert.equal(result.perImage.length, spec.length);
    assert.equal(result.groundTruths.length, totalBoxes);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("harness end to end with noop stub yields zero metrics", async () => {
  const dir = await mkdtemp(path.join(tmpdir(), "cybersend-stub-eval-"));
  try {
    const spec = await writeFixture(dir);
    const totalBoxes = spec.reduce((sum, image) => sum + image.boxes.length, 0);
    const noop = new StubDetector({ mode: "noop" });
    const result = await evaluateSplit(noop, dir, {
      iou: IOU,
      confidence: CONFIDENCE,
      scoreFloor: SCORE_FLOOR,
    });
    assert.equal(result.metrics.precision, 0);
    assert.equal(result.metrics.recall, 0);
    assert.equal(result.metrics.map05, 0);
    assert.equal(result.metrics.tp, 0);
    assert.equal(result.metrics.fp, 0);
    assert.equal(result.metrics.fn, totalBoxes);
    assert.ok(
      result.perImage.every((row) => row.detections === 0),
      "noop stub must produce zero detections per image",
    );
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("harness fails loudly when the JPEG size disagrees with the annotation file", async () => {
  const dir = await mkdtemp(path.join(tmpdir(), "cybersend-stub-eval-"));
  try {
    const spec = await writeFixture(dir);
    const lookup = oracleBoxesByFile(spec);
    const first = spec[0];
    assert.ok(first !== undefined);
    const cocoPath = path.join(dir, "_annotations.coco.json");
    const { readFile, writeFile } = await import("node:fs/promises");
    const coco = JSON.parse(await readFile(cocoPath, "utf8")) as { images: Array<{ id: number; width: number; height: number }> };
    const row = coco.images.find((image) => image.id === 1);
    assert.ok(row !== undefined);
    row.width += 1;
    await writeFile(cocoPath, JSON.stringify(coco));
    const oracle = new StubDetector({ mode: "oracle", boxesByFile: lookup, score: 0.9 });
    await assert.rejects(
      () => evaluateSplit(oracle, dir, { iou: IOU, confidence: CONFIDENCE, scoreFloor: SCORE_FLOOR }),
      /says/,
    );
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
