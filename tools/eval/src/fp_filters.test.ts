/**
 * Unit tests for the pure post-processing filters (no model, no I/O).
 * Run: npm test (node --test).
 */

import assert from "node:assert/strict";
import { test } from "node:test";

import { areaFilter, borderFilter, dedupe, operatingMetrics } from "./fp_filters.ts";
import type { Detection, GroundTruth } from "./metrics.ts";

function det(partial: Partial<Detection> & { imageIndex: number; score: number }): Detection {
  return { x1: 0, y1: 0, x2: 10, y2: 10, ...partial };
}

function gt(partial: Partial<GroundTruth> & { imageIndex: number }): GroundTruth {
  return { x1: 0, y1: 0, x2: 10, y2: 10, ...partial };
}

test("dedupe: keeps the highest scoring box and drops an overlapping one", () => {
  const kept = dedupe(
    [
      det({ imageIndex: 0, score: 0.9 }),
      det({ imageIndex: 0, score: 0.8, x1: 1, y1: 1, x2: 11, y2: 11 }),
    ],
    0.5,
  );
  assert.equal(kept.length, 1);
  assert.equal(kept[0]?.score, 0.9);
});

test("dedupe: keeps boxes that do not overlap", () => {
  const kept = dedupe(
    [
      det({ imageIndex: 0, score: 0.9 }),
      det({ imageIndex: 0, score: 0.8, x1: 100, y1: 100, x2: 110, y2: 110 }),
    ],
    0.5,
  );
  assert.equal(kept.length, 2);
});

test("dedupe: does not suppress across images", () => {
  const kept = dedupe(
    [
      det({ imageIndex: 0, score: 0.9 }),
      det({ imageIndex: 1, score: 0.8 }),
    ],
    0.5,
  );
  assert.equal(kept.length, 2);
});

test("areaFilter: drops boxes below the floor and keeps the rest", () => {
  const kept = areaFilter(
    [
      det({ imageIndex: 0, score: 0.9, x2: 5, y2: 5 }),
      det({ imageIndex: 0, score: 0.8, x2: 20, y2: 20 }),
    ],
    100,
  );
  assert.equal(kept.length, 1);
  assert.equal(kept[0]?.score, 0.8);
});

test("borderFilter: drops boxes touching the frame edge", () => {
  const kept = borderFilter(
    [
      det({ imageIndex: 0, score: 0.9, x1: 0, y1: 100, x2: 50, y2: 150 }),
      det({ imageIndex: 0, score: 0.8, x1: 100, y1: 100, x2: 150, y2: 150 }),
    ],
    2,
  );
  assert.equal(kept.length, 1);
  assert.equal(kept[0]?.score, 0.8);
});

test("operatingMetrics: counts a matched box as true positive and an unmatched as false positive", () => {
  const metrics = operatingMetrics(
    [
      det({ imageIndex: 0, score: 0.9 }),
      det({ imageIndex: 0, score: 0.8, x1: 200, y1: 200, x2: 210, y2: 210 }),
    ],
    [gt({ imageIndex: 0 })],
    1,
    0.5,
  );
  assert.equal(metrics.tp, 1);
  assert.equal(metrics.fp, 1);
  assert.equal(metrics.fn, 0);
  assert.equal(metrics.precision, 0.5);
  assert.equal(metrics.recall, 1);
  assert.equal(metrics.fpPerImage, 1);
  assert.equal(metrics.medianAbsCountError, 1);
});
