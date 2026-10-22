/**
 * Unit tests for the YOLOX decode path (pure typed arrays, no model needed).
 * Run: npm test (node --test).
 */

import assert from "node:assert/strict";
import { test } from "node:test";

import type * as ort from "onnxruntime-node";

import { decodeYoloxOutputs, nmsIndices } from "./decode_yolox.ts";
import { letterboxToTensor, normalizeToNchw } from "./preprocess.ts";

/** Build a fake ONNX tensor the decode can read, without loading any model. */
function fakeTensor(dims: readonly number[], data: readonly number[]): ort.Tensor {
  return { dims, data: new Float32Array(data) } as unknown as ort.Tensor;
}

test("decodeYoloxOutputs: cxcywh pixels become xyxy with obj times class score", () => {
  const results = { output: fakeTensor([1, 1, 6], [100, 200, 40, 20, 0.9, 0.8]) };
  const decoded = decodeYoloxOutputs(results, 640);
  assert.equal(decoded.numAnchors, 1);
  assert.deepEqual(Array.from(decoded.boxes), [80, 190, 120, 210]);
  assert.ok(Math.abs((decoded.scores[0] ?? 0) - 0.72) < 1e-6);
});

test("decodeYoloxOutputs: boxes are clipped into the frame", () => {
  const results = { output: fakeTensor([1, 1, 6], [5, 635, 40, 20, 0.5, 0.5]) };
  const decoded = decodeYoloxOutputs(results, 640);
  assert.deepEqual(Array.from(decoded.boxes), [0, 625, 25, 640]);
});

test("decodeYoloxOutputs: takes the best class score when several classes exist", () => {
  const results = {
    output: fakeTensor([1, 2, 8], [
      100, 100, 10, 10, 0.5, 0.1, 0.4, 0.0,
      300, 300, 10, 10, 0.5, 0.2, 0.3, 0.0,
    ]),
  };
  const decoded = decodeYoloxOutputs(results, 640);
  assert.ok(Math.abs((decoded.scores[0] ?? 0) - 0.2) < 1e-6);
  assert.ok(Math.abs((decoded.scores[1] ?? 0) - 0.15) < 1e-6);
});

test("decodeYoloxOutputs: rejects a tensor that is not [1, anchors, 6+]", () => {
  assert.throws(
    () => decodeYoloxOutputs({ dets: fakeTensor([1, 300, 4], [0, 0, 0, 0]) }, 640),
    /unexpected YOLOX outputs/,
  );
});

test("nmsIndices: suppresses a duplicate and keeps a separated box", () => {
  const boxes = [
    100, 100, 140, 120, // A
    101, 101, 141, 121, // duplicate of A, lower score
    400, 400, 440, 420, // B, far away
  ];
  const scores = [0.9, 0.8, 0.7];
  const kept = nmsIndices(boxes, scores, 3, 0.65);
  assert.deepEqual(kept, [0, 2]);
});

test("nmsIndices: honours the score floor and skips non-positive scores", () => {
  const boxes = [
    100, 100, 140, 120,
    400, 400, 440, 420,
    200, 200, 240, 220,
  ];
  const scores = [0.9, 0.005, 0];
  const kept = nmsIndices(boxes, scores, 3, 0.65, 0.01);
  assert.deepEqual(kept, [0]);
  assert.deepEqual(nmsIndices(boxes, scores, 3, 0.65), [0, 1]);
});

test("normalizeToNchw raw mode keeps 0..255 values and differs from imagenet", () => {
  const size = 2;
  const rgb = new Uint8Array([10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120]);
  const raw = normalizeToNchw(rgb, size, "raw");
  assert.deepEqual(Array.from(raw.subarray(0, 4)), [10, 40, 70, 100]);
  assert.equal(raw[size * size], 20);
  const imagenet = normalizeToNchw(rgb, size);
  assert.notEqual(raw[0], imagenet[0]);
});

test("letterboxToTensor raw mode keeps the 114 pad value unscaled", () => {
  const rgba = new Uint8Array(640 * 640 * 4);
  for (let index = 0; index < 640 * 640; index += 1) {
    rgba[index * 4] = 200;
    rgba[index * 4 + 1] = 200;
    rgba[index * 4 + 2] = 200;
    rgba[index * 4 + 3] = 255;
  }
  const { data } = letterboxToTensor(rgba, 640, 640, 640, "raw");
  assert.equal(data[0], 200);
  assert.equal(data[640 * 640], 200);
});
