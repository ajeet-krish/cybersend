/**
 * Deterministic synthetic eval fixture for the stub detector runs.
 *
 * Generates small JPEG wall-like images with painted hold rectangles plus a
 * matching COCO annotation file (single class id 0, xywh boxes in source
 * pixels) under a target directory. Everything is derived from a fixed seed,
 * so the fixture is byte-stable across runs and no binary fixture needs to be
 * committed.
 */

import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";

import { encode as encodeJpeg } from "jpeg-js";

export interface FixtureBox {
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
}

export interface FixtureImage {
  readonly fileName: string;
  readonly width: number;
  readonly height: number;
  readonly boxes: FixtureBox[];
}

const SIZES: ReadonlyArray<readonly [number, number]> = [
  [320, 240],
  [640, 640],
  [500, 700],
  [800, 450],
];

/** Tiny deterministic LCG so the fixture needs no randomness dependency. */
function lcg(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    return state / 0x100000000;
  };
}

/** Build the fixture spec (no I/O): deterministic boxes per image. */
export function buildFixtureSpec(seed = 20261019): FixtureImage[] {
  const random = lcg(seed);
  return SIZES.map(([width, height], imageIndex) => {
    const boxCount = 3 + Math.floor(random() * 4);
    const boxes: FixtureBox[] = [];
    for (let index = 0; index < boxCount; index += 1) {
      const boxWidth = 30 + Math.floor(random() * 60);
      const boxHeight = 30 + Math.floor(random() * 60);
      const x = 10 + Math.floor(random() * Math.max(1, width - boxWidth - 20));
      const y = 10 + Math.floor(random() * Math.max(1, height - boxHeight - 20));
      boxes.push({ x, y, width: boxWidth, height: boxHeight });
    }
    return { fileName: `images/fixture_${imageIndex}.jpg`, width, height, boxes };
  });
}

/** Paint one fixture image as RGBA bytes: vertical gradient plus filled boxes. */
function renderRgba(image: FixtureImage, imageIndex: number): Uint8Array {
  const rgba = new Uint8Array(image.width * image.height * 4);
  const random = lcg(1000 + imageIndex);
  const holdTone = 40 + Math.floor(random() * 160);
  for (let y = 0; y < image.height; y += 1) {
    const rowTone = Math.round((y / image.height) * 120) + 60;
    for (let x = 0; x < image.width; x += 1) {
      const offset = (y * image.width + x) * 4;
      rgba[offset] = rowTone;
      rgba[offset + 1] = Math.min(255, rowTone + 20);
      rgba[offset + 2] = Math.min(255, rowTone + 40);
      rgba[offset + 3] = 255;
    }
  }
  for (const box of image.boxes) {
    for (let y = box.y; y < Math.min(image.height, box.y + box.height); y += 1) {
      for (let x = box.x; x < Math.min(image.width, box.x + box.width); x += 1) {
        const offset = (y * image.width + x) * 4;
        rgba[offset] = holdTone;
        rgba[offset + 1] = 255 - holdTone;
        rgba[offset + 2] = Math.round(holdTone / 2);
        rgba[offset + 3] = 255;
      }
    }
  }
  return rgba;
}

/** Write the fixture JPEGs and COCO JSON into the target directory. */
export async function writeFixture(dir: string, seed = 20261019): Promise<FixtureImage[]> {
  const spec = buildFixtureSpec(seed);
  await mkdir(path.join(dir, "images"), { recursive: true });

  const images = spec.map((image, index) => ({
    id: index + 1,
    file_name: image.fileName,
    width: image.width,
    height: image.height,
  }));
  const annotations: Array<{
    id: number;
    image_id: number;
    category_id: number;
    bbox: number[];
    area: number;
    iscrowd: number;
  }> = [];
  let annotationId = 1;
  for (const [index, image] of spec.entries()) {
    const encoded = encodeJpeg({
      data: renderRgba(image, index),
      width: image.width,
      height: image.height,
    });
    await writeFile(path.join(dir, image.fileName), Buffer.from(encoded.data));
    for (const box of image.boxes) {
      annotations.push({
        id: annotationId,
        image_id: index + 1,
        category_id: 0,
        bbox: [box.x, box.y, box.width, box.height],
        area: box.width * box.height,
        iscrowd: 0,
      });
      annotationId += 1;
    }
  }
  const coco = {
    info: { description: "CyberSend stub eval fixture (synthetic, not training data)", version: "1.0" },
    licenses: [],
    categories: [{ id: 0, name: "hold", supercategory: "climb" }],
    images,
    annotations,
  };
  await writeFile(path.join(dir, "_annotations.coco.json"), `${JSON.stringify(coco, null, 2)}\n`, "utf8");
  return spec;
}
