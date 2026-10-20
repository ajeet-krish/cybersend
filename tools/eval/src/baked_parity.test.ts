/**
 * Preprocess parity with the baked dataset (tools/train hold-bake).
 *
 * With letterbox-640 baked into datasets/merged, every merged image is already
 * 640x640 with centered pad value 114, so the harness letterbox on that data is
 * an exact identity: scale 1, zero pads, no resampling. These tests pin that
 * contract from the harness side:
 *
 *   1. a synthetic baked frame passes through letterboxRgba byte for byte,
 *   2. letterboxToSourceBox and gtBoxToLetterbox reduce to identity,
 *   3. the harness geometry matches the bake rounding on the half-up case
 *      (1280x641: content height 320.5 -> 321, padY 159),
 *   4. the real baked val split (when present on disk) round trips: decoded
 *      bytes are unchanged by the letterbox and every box sits inside the
 *      canvas with category id 1.
 *
 * Run: npm test (node --test). Test 4 skips when the merged dataset has not
 * been built on this machine (datasets/ is git-ignored).
 */

import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import { decode as decodeJpeg } from "jpeg-js";

import { gtBoxToLetterbox } from "./evaluate.ts";
import {
  PAD_VALUE,
  TARGET_SIZE,
  letterboxGeometryFor,
  letterboxRgba,
  letterboxToSourceBox,
} from "./preprocess.ts";

const EVAL_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const BAKED_VAL_DIR = path.resolve(EVAL_ROOT, "..", "train", "datasets", "merged", "val");

/**
 * Skip reason for the real-dataset test: the merged dataset is git-ignored, so
 * it may be missing (never built) or present but not baked yet (hold-build was
 * rerun without hold-bake). Once manifest.json carries a "bake" section the
 * assertions below run and must hold.
 */
function bakedDatasetSkipReason(): string | false {
  const annotationsPath = path.join(BAKED_VAL_DIR, "_annotations.coco.json");
  if (!existsSync(annotationsPath)) {
    return "datasets/merged not built on this machine (run uv run hold-build && uv run hold-bake)";
  }
  const manifestPath = path.join(BAKED_VAL_DIR, "..", "manifest.json");
  if (!existsSync(manifestPath)) {
    return "datasets/merged/manifest.json missing (run uv run hold-build)";
  }
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8")) as { bake?: unknown };
  if (manifest.bake === undefined) {
    return "datasets/merged not baked yet (run uv run hold-bake)";
  }
  return false;
}

/** Deterministic varied RGBA frame (not a flat color, so identity is meaningful). */
function patternedRgba(size: number): Uint8Array {
  const rgba = new Uint8Array(size * size * 4);
  for (let y = 0; y < size; y += 1) {
    for (let x = 0; x < size; x += 1) {
      const index = (y * size + x) * 4;
      rgba[index] = (x * 7 + y * 3) % 256;
      rgba[index + 1] = (y * 5 + x) % 256;
      rgba[index + 2] = (x + y * 11) % 256;
      rgba[index + 3] = 255;
    }
  }
  return rgba;
}

function assertRgbMatchesRgba(rgb: Uint8Array, rgba: Uint8Array, what: string): void {
  assert.equal(rgb.length, (rgba.length / 4) * 3, `${what}: rgb length`);
  for (let pixel = 0; pixel < rgba.length / 4; pixel += 1) {
    for (let channel = 0; channel < 3; channel += 1) {
      const actual = rgb[pixel * 3 + channel];
      const expected = rgba[pixel * 4 + channel];
      if (actual !== expected) {
        assert.fail(
          `${what}: byte mismatch at pixel ${pixel} channel ${channel}: ${actual} != ${expected}`,
        );
      }
    }
  }
}

test("letterboxRgba is an exact identity on a synthetic baked 640x640 frame", () => {
  const rgba = patternedRgba(TARGET_SIZE);
  const { rgb, meta } = letterboxRgba(rgba, TARGET_SIZE, TARGET_SIZE);
  assert.equal(meta.scale, 1);
  assert.equal(meta.padX, 0);
  assert.equal(meta.padY, 0);
  assertRgbMatchesRgba(rgb, rgba, "synthetic baked frame");
});

test("boxes map through the baked identity without moving", () => {
  const meta = {
    scale: 1,
    padX: 0,
    padY: 0,
    size: TARGET_SIZE,
    sourceWidth: TARGET_SIZE,
    sourceHeight: TARGET_SIZE,
  } as const;

  // letterboxed frame pixel box -> normalized 0..1 source box: pure division.
  const back = letterboxToSourceBox([64, 128, 256, 384], meta);
  assert.ok(Math.abs(back.x1 - 0.1) < 1e-12);
  assert.ok(Math.abs(back.y1 - 0.2) < 1e-12);
  assert.ok(Math.abs(back.x2 - 0.4) < 1e-12);
  assert.ok(Math.abs(back.y2 - 0.6) < 1e-12);

  // Ground truth in the baked frame maps to the model frame unchanged.
  const box = gtBoxToLetterbox([64, 128, 192, 256], meta.scale, meta.padX, meta.padY);
  assert.deepEqual(box, { x1: 64, y1: 128, x2: 256, y2: 384 });
});

test("harness geometry matches hold-bake on the half-up rounding case", () => {
  // 1280x641 letterboxes to content height 320.5; JavaScript Math.round gives
  // 321 (padY 159). Python's banker's rounding would give 320 (padY 160), so
  // this asserts the bake and the harness agree on the boundary case.
  const geometry = letterboxGeometryFor(1280, 641);
  assert.equal(geometry.scale, 0.5);
  assert.equal(geometry.padX, 0);
  assert.equal(geometry.padY, 159);
});

test(
  "baked val split round trips through the harness letterbox",
  {
    skip: bakedDatasetSkipReason(),
  },
  () => {
    const coco = JSON.parse(
      readFileSync(path.join(BAKED_VAL_DIR, "_annotations.coco.json"), "utf8"),
    ) as {
      images: Array<{
        id: number;
        file_name: string;
        width: number;
        height: number;
        source_width?: number;
        source_height?: number;
        letterbox_scale?: number;
        letterbox_pad_x?: number;
        letterbox_pad_y?: number;
      }>;
      annotations: Array<{
        image_id: number;
        category_id: number;
        bbox: [number, number, number, number];
      }>;
      categories: Array<{ id: number }>;
    };

    assert.ok(coco.images.length > 0, "val split has images");
    assert.deepEqual(
      coco.categories.map((category) => category.id),
      [1],
      "baked split declares exactly category id 1",
    );
    for (const image of coco.images) {
      assert.equal(image.width, TARGET_SIZE, `${image.file_name} width`);
      assert.equal(image.height, TARGET_SIZE, `${image.file_name} height`);
    }

    for (const annotation of coco.annotations) {
      assert.equal(annotation.category_id, 1, "no category id 0 survives the bake");
      const [x, y, boxWidth, boxHeight] = annotation.bbox;
      assert.ok(boxWidth >= 2 && boxHeight >= 2, `degenerate box ${JSON.stringify(annotation.bbox)}`);
      assert.ok(
        x >= -1e-6 && y >= -1e-6 && x + boxWidth <= TARGET_SIZE + 1e-6 && y + boxHeight <= TARGET_SIZE + 1e-6,
        `box outside the canvas: ${JSON.stringify(annotation.bbox)}`,
      );
    }
    const sample = coco.images[0];
    assert.ok(sample !== undefined);
    const bytes = readFileSync(path.join(BAKED_VAL_DIR, sample.file_name));
    const decoded = decodeJpeg(bytes, { useTArray: true, maxMemoryUsageInMB: 512 });
    assert.equal(decoded.width, TARGET_SIZE);
    assert.equal(decoded.height, TARGET_SIZE);

    // The round trip: harness letterbox over baked pixels changes nothing.
    const { rgb, meta } = letterboxRgba(decoded.data, decoded.width, decoded.height);
    assert.equal(meta.scale, 1);
    assert.equal(meta.padX, 0);
    assert.equal(meta.padY, 0);
    assertRgbMatchesRgba(rgb, decoded.data, `baked ${sample.file_name}`);

    // Pad rows carry the pad value wherever the recorded geometry says padding
    // exists, and the frame is a real image, not a flat pad canvas.
    const padX = sample.letterbox_pad_x;
    const padY = sample.letterbox_pad_y;
    assert.equal(typeof padX, "number", "baked image records letterbox_pad_x");
    assert.equal(typeof padY, "number", "baked image records letterbox_pad_y");
    assert.equal(typeof sample.source_width, "number", "baked image records source_width");
    if (padY !== undefined && padY > 0) {
      for (let x = 0; x < TARGET_SIZE; x += 1) {
        assert.equal(rgb[x * 3], PAD_VALUE, "top pad row is the pad value");
      }
      const bottomRowStart = (TARGET_SIZE - 1) * TARGET_SIZE * 3;
      for (let x = 0; x < TARGET_SIZE; x += 1) {
        assert.equal(rgb[bottomRowStart + x * 3], PAD_VALUE, "bottom pad row is the pad value");
      }
    }
    assert.ok(
      rgb.some((value) => value !== PAD_VALUE),
      "baked frame should contain image content, not only pad value",
    );
  },
);
