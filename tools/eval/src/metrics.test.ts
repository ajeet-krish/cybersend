/**
 * Unit tests for the pure detection metrics (no model, no I/O).
 * Run: npm test (node --test).
 */

import assert from "node:assert/strict";
import { test } from "node:test";

import { averagePrecision, iou, matchDetections, mean, median, type Detection, type GroundTruth } from "./metrics.ts";

function det(partial: Partial<Detection> & { imageIndex: number; score: number }): Detection {
  return { x1: 0, y1: 0, x2: 10, y2: 10, ...partial };
}

function gt(partial: Partial<GroundTruth> & { imageIndex: number }): GroundTruth {
  return { x1: 0, y1: 0, x2: 10, y2: 10, ...partial };
}

test("iou: identical boxes are 1", () => {
  assert.equal(iou(det({ imageIndex: 0, score: 1 }), gt({ imageIndex: 0 })), 1);
});

test("iou: disjoint boxes are 0", () => {
  const a = det({ imageIndex: 0, score: 1, x1: 0, y1: 0, x2: 10, y2: 10 });
  const b = gt({ imageIndex: 0, x1: 20, y1: 20, x2: 30, y2: 30 });
  assert.equal(iou(a, b), 0);
});

test("iou: half overlap computes correctly", () => {
  const a = det({ imageIndex: 0, score: 1, x1: 0, y1: 0, x2: 10, y2: 10 });
  const b = gt({ imageIndex: 0, x1: 5, y1: 0, x2: 15, y2: 10 });
  // inter 5*10 = 50, union 100 + 100 - 50 = 150
  assert.ok(Math.abs(iou(a, b) - 50 / 150) < 1e-12);
});

test("matchDetections: higher confidence claims the ground truth first", () => {
  const groundTruths = [gt({ imageIndex: 0 })];
  const detections = [
    det({ imageIndex: 0, score: 0.9 }),
    det({ imageIndex: 0, score: 0.8 }),
  ];
  const result = matchDetections(detections, groundTruths, 0.5, 1);
  assert.deepEqual(result.tpFlags, [true, false]);
  assert.equal(result.tpCount, 1);
  assert.equal(result.fpCount, 1);
});

test("matchDetections: detections in other images never match", () => {
  const groundTruths = [gt({ imageIndex: 0 })];
  const detections = [det({ imageIndex: 1, score: 0.9 })];
  const result = matchDetections(detections, groundTruths, 0.5, 2);
  assert.deepEqual(result.tpFlags, [false]);
});

test("matchDetections: below-threshold IoU is a false positive", () => {
  const groundTruths = [gt({ imageIndex: 0 })];
  const detections = [det({ imageIndex: 0, score: 0.9, x1: 8, y1: 8, x2: 18, y2: 18 })];
  const result = matchDetections(detections, groundTruths, 0.5, 1);
  assert.deepEqual(result.tpFlags, [false]);
});

test("averagePrecision: perfect ranking is 1", () => {
  assert.equal(averagePrecision([true, true, true], 3), 1);
});

test("averagePrecision: no true positives is 0", () => {
  assert.equal(averagePrecision([false, false], 2), 0);
});

test("averagePrecision: known VOC 2010+ example", () => {
  // 4 GT: ranked flags TP FP TP TP -> precisions 1, .5, .667, .75; recalls .25, .25, .5, .75
  // envelope pe(r) = max precision at recall >= r: pe(.25)=1, pe(.5)=.75, pe(.75)=.75
  // AP = .25*1 + .25*.75 + .25*.75 = .625
  const ap = averagePrecision([true, false, true, true], 4);
  assert.ok(Math.abs(ap - 0.625) < 1e-12, `ap ${ap} vs 0.625`);
});

test("averagePrecision: second known VOC 2010+ example", () => {
  // ranked flags TP TP FP TP over 4 GT: recalls .25, .5, .5, .75; precisions 1, 1, .667, .75
  // envelope pe(r): pe(0..0.25]=1, pe(.25..0.5]=1, pe(.5..0.75]=.75
  // AP = .25*1 + .25*1 + .25*.75 = .6875
  const ap = averagePrecision([true, true, false, true], 4);
  assert.ok(Math.abs(ap - 0.6875) < 1e-12, `ap ${ap} vs 0.6875`);
});

test("averagePrecision: empty inputs are 0", () => {
  assert.equal(averagePrecision([], 0), 0);
  assert.equal(averagePrecision([], 5), 0);
});

test("median: odd and even lengths", () => {
  assert.equal(median([3, 1, 2]), 2);
  assert.equal(median([4, 1, 2, 3]), 2.5);
  assert.equal(median([]), 0);
});

test("mean: basic and empty", () => {
  assert.equal(mean([2, 4, 6]), 4);
  assert.equal(mean([]), 0);
});
