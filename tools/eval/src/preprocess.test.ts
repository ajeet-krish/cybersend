/**
 * Unit tests for the shared inference preprocess contract (pure typed arrays).
 * Run: npm test (node --test).
 */

import assert from "node:assert/strict";
import { test } from "node:test";

import {
  IMAGENET_MEAN,
  IMAGENET_STD,
  PAD_VALUE,
  TARGET_SIZE,
  letterboxGeometryFor,
  letterboxRgba,
  letterboxToSourceBox,
  letterboxToTensor,
  normalizeToNchw,
} from "./preprocess.ts";

function solidRgba(width: number, height: number, gray: number): Uint8Array {
  const rgba = new Uint8Array(width * height * 4);
  for (let index = 0; index < width * height; index += 1) {
    rgba[index * 4] = gray;
    rgba[index * 4 + 1] = gray;
    rgba[index * 4 + 2] = gray;
    rgba[index * 4 + 3] = 255;
  }
  return rgba;
}

test("letterboxGeometryFor: square source is identity with zero pads", () => {
  const geometry = letterboxGeometryFor(TARGET_SIZE, TARGET_SIZE);
  assert.equal(geometry.scale, 1);
  assert.equal(geometry.padX, 0);
  assert.equal(geometry.padY, 0);
});

test("letterboxGeometryFor: wide source is letterboxed vertically", () => {
  const geometry = letterboxGeometryFor(1280, 640);
  assert.equal(geometry.scale, 0.5);
  assert.equal(geometry.padX, 0);
  assert.equal(geometry.padY, 160);
});

test("letterboxRgba: square 640 source passes through unchanged", () => {
  const rgba = solidRgba(640, 640, 200);
  const result = letterboxRgba(rgba, 640, 640);
  assert.equal(result.rgb.length, 640 * 640 * 3);
  // center pixel is source gray, no padding anywhere
  assert.equal(result.rgb[(320 * 640 + 320) * 3], 200);
  assert.equal(result.rgb[0], 200);
});

test("letterboxRgba: pads with PAD_VALUE outside the content area", () => {
  const rgba = solidRgba(640, 320, 200);
  const result = letterboxRgba(rgba, 640, 320);
  const topCenter = (10 * TARGET_SIZE + 320) * 3;
  assert.equal(result.rgb[topCenter], PAD_VALUE);
  const middleCenter = ((160 + 10) * TARGET_SIZE + 320) * 3;
  assert.equal(result.rgb[middleCenter], 200);
  assert.equal(result.meta.padY, 160);
});

test("normalizeToNchw: length, layout, and known value", () => {
  const rgb = new Uint8Array(4 * 4 * 3);
  rgb.fill(255);
  const out = normalizeToNchw(rgb, 4);
  assert.equal(out.length, 48);
  const expectedR = (1 - IMAGENET_MEAN[0]) / IMAGENET_STD[0];
  assert.ok(Math.abs((out[0] ?? 0) - expectedR) < 1e-6, `R channel ${out[0]} vs ${expectedR}`);
  const expectedG = (1 - IMAGENET_MEAN[1]) / IMAGENET_STD[1];
  assert.ok(Math.abs((out[16] ?? 0) - expectedG) < 1e-6, `G plane ${out[16]} vs ${expectedG}`);
});

test("letterboxToTensor: combines letterbox and normalize", () => {
  const rgba = solidRgba(640, 640, 114);
  const { data, meta } = letterboxToTensor(rgba, 640, 640);
  assert.equal(data.length, 3 * TARGET_SIZE * TARGET_SIZE);
  assert.equal(meta.scale, 1);
  const expected = (114 / 255 - IMAGENET_MEAN[0]) / IMAGENET_STD[0];
  assert.ok(Math.abs((data[0] ?? 0) - expected) < 1e-6);
});

test("letterboxToSourceBox: round trip through the geometry", () => {
  const rgba = solidRgba(640, 320, 100);
  const { meta } = letterboxToTensor(rgba, 640, 320);
  // a box at the top-left of the source maps into the letterbox frame and back
  const source: readonly [number, number, number, number] = [10, 20, 30, 40];
  const x1 = source[0] * meta.scale + meta.padX;
  const y1 = source[1] * meta.scale + meta.padY;
  const back = letterboxToSourceBox([x1, y1, x1 + source[2] * meta.scale, y1 + source[3] * meta.scale], meta);
  assert.ok(Math.abs(back.x1 - 10 / 640) < 1e-9);
  assert.ok(Math.abs(back.y1 - 20 / 320) < 1e-9);
  assert.ok(Math.abs(back.x2 - 40 / 640) < 1e-9);
  assert.ok(Math.abs(back.y2 - 60 / 320) < 1e-9);
});

test("letterboxToSourceBox: clamps outside content into the source image", () => {
  const back = letterboxToSourceBox([-50, -50, 9999, 9999], {
    scale: 1,
    padX: 0,
    padY: 0,
    size: TARGET_SIZE,
    sourceWidth: TARGET_SIZE,
    sourceHeight: TARGET_SIZE,
  });
  assert.equal(back.x1, 0);
  assert.equal(back.y1, 0);
  assert.equal(back.x2, 1);
  assert.equal(back.y2, 1);
});
