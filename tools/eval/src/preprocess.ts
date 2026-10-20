/**
 * Pure typed-array preprocessing for the CyberSend hold detector.
 *
 * This file is the single source of truth for the inference preprocess contract and is
 * shared between the app (src/features/ml/preprocess.ts wraps or mirrors it) and the
 * Node eval harness (tools/eval). It must stay in lockstep with the training convention
 * recorded in tools/train/artifacts/manifest.json and baked into the data by
 * tools/train/src/hold_train/bake_dataset.py (merged D1 dataset) and
 * tools/train/src/hold_train/split_dataset.py (own-gym photos):
 *
 *   1. letterbox the image into a square canvas of TARGET_SIZE with pad value 114,
 *      centered, aspect ratio preserved;
 *   2. RGB float32 NCHW tensor with (value / 255 - mean) / std (ImageNet stats).
 *
 * Decoders (Skia in the app, jpeg-js in the eval harness) only produce RGBA bytes.
 * Everything from RGBA onward lives here, with no native imports.
 */

export const TARGET_SIZE = 640;
export const PAD_VALUE = 114;
export const IMAGENET_MEAN: readonly [number, number, number] = [0.485, 0.456, 0.406];
export const IMAGENET_STD: readonly [number, number, number] = [0.229, 0.224, 0.225];

/** Geometry of the letterbox transform, needed to map detections back to source pixels. */
export interface LetterboxMeta {
  readonly scale: number;
  readonly padX: number;
  readonly padY: number;
  readonly size: number;
  readonly sourceWidth: number;
  readonly sourceHeight: number;
}

/** Pure geometry of the letterbox transform: scale plus centered pad offsets. */
export function letterboxGeometryFor(
  sourceWidth: number,
  sourceHeight: number,
  size: number = TARGET_SIZE,
): { readonly scale: number; readonly padX: number; readonly padY: number } {
  const scale = Math.min(size / sourceWidth, size / sourceHeight);
  const contentWidth = Math.max(1, Math.round(sourceWidth * scale));
  const contentHeight = Math.max(1, Math.round(sourceHeight * scale));
  return {
    scale,
    padX: Math.floor((size - contentWidth) / 2),
    padY: Math.floor((size - contentHeight) / 2),
  };
}

export interface LetterboxResult {
  /** size x size x 3 uint8 RGB, padded with PAD_VALUE. */
  readonly rgb: Uint8Array;
  readonly meta: LetterboxMeta;
}

export interface TensorResult {
  /** float32 NCHW tensor data, length 3 * size * size. */
  readonly data: Float32Array;
  readonly meta: LetterboxMeta;
}

export interface SourceBox {
  /** x1..y2 normalized to 0..1 over the original (un-letterboxed) image. */
  readonly x1: number;
  readonly y1: number;
  readonly x2: number;
  readonly y2: number;
}

/**
 * Letterbox RGBA bytes into a square RGB canvas with centered padding.
 *
 * Resampling is bilinear on center-aligned sample positions, which is an exact identity
 * when the source is already TARGET_SIZE wide or tall after scaling. The merged D1
 * dataset (hold-bake) and the own-gym splits (hold-split) are written already letterboxed
 * to 640x640 with PIL BICUBIC, so the eval harness feeds those pre-letterboxed images and
 * no resampling happens there at all, and the app path shares this exact code.
 */
export function letterboxRgba(
  rgba: Uint8Array,
  sourceWidth: number,
  sourceHeight: number,
  size: number = TARGET_SIZE,
  padValue: number = PAD_VALUE,
): LetterboxResult {
  if (sourceWidth <= 0 || sourceHeight <= 0) {
    throw new Error(`invalid source size ${sourceWidth}x${sourceHeight}`);
  }
  if (rgba.length !== sourceWidth * sourceHeight * 4) {
    throw new Error(
      `rgba length ${rgba.length} does not match ${sourceWidth}x${sourceHeight} x4`,
    );
  }

  const { scale, padX, padY } = letterboxGeometryFor(sourceWidth, sourceHeight, size);
  const contentWidth = Math.max(1, Math.round(sourceWidth * scale));
  const contentHeight = Math.max(1, Math.round(sourceHeight * scale));

  const rgb = new Uint8Array(size * size * 3);
  rgb.fill(padValue);

  for (let y = 0; y < contentHeight; y += 1) {
    const sourceY = (y - padY + 0.5) / scale - 0.5;
    const y0 = Math.floor(sourceY);
    const fy = sourceY - y0;
    const y1 = Math.min(Math.max(y0 + 1, 0), sourceHeight - 1);
    const y0c = Math.min(Math.max(y0, 0), sourceHeight - 1);
    for (let x = 0; x < contentWidth; x += 1) {
      const sourceX = (x - padX + 0.5) / scale - 0.5;
      const x0 = Math.floor(sourceX);
      const fx = sourceX - x0;
      const x1 = Math.min(Math.max(x0 + 1, 0), sourceWidth - 1);
      const x0c = Math.min(Math.max(x0, 0), sourceWidth - 1);

      const outIndex = ((y + padY) * size + (x + padX)) * 3;
      for (let channel = 0; channel < 3; channel += 1) {
        const p00 = rgba[(y0c * sourceWidth + x0c) * 4 + channel] ?? 0;
        const p01 = rgba[(y0c * sourceWidth + x1) * 4 + channel] ?? 0;
        const p10 = rgba[(y1 * sourceWidth + x0c) * 4 + channel] ?? 0;
        const p11 = rgba[(y1 * sourceWidth + x1) * 4 + channel] ?? 0;
        const top = p00 + (p01 - p00) * fx;
        const bottom = p10 + (p11 - p10) * fx;
        rgb[outIndex + channel] = Math.round(top + (bottom - top) * fy);
      }
    }
  }

  return {
    rgb,
    meta: {
      scale,
      padX,
      padY,
      size,
      sourceWidth,
      sourceHeight,
    },
  };
}

/** Convert size x size x 3 uint8 RGB into a normalized float32 NCHW tensor. */
export function normalizeToNchw(rgb: Uint8Array, size: number): Float32Array {
  const plane = size * size;
  if (rgb.length !== plane * 3) {
    throw new Error(`rgb length ${rgb.length} does not match ${size}x${size} x3`);
  }
  const out = new Float32Array(plane * 3);
  const channels: ReadonlyArray<readonly [number, number, number]> = [
    [0, IMAGENET_MEAN[0], IMAGENET_STD[0]],
    [1, IMAGENET_MEAN[1], IMAGENET_STD[1]],
    [2, IMAGENET_MEAN[2], IMAGENET_STD[2]],
  ];
  for (const [channel, mean, std] of channels) {
    const offset = channel * plane;
    for (let i = 0; i < plane; i += 1) {
      out[offset + i] = ((rgb[i * 3 + channel] ?? 0) / 255 - mean) / std;
    }
  }
  return out;
}

/** Letterbox RGBA bytes and normalize into a float32 NCHW tensor in one step. */
export function letterboxToTensor(
  rgba: Uint8Array,
  sourceWidth: number,
  sourceHeight: number,
  size: number = TARGET_SIZE,
): TensorResult {
  const { rgb, meta } = letterboxRgba(rgba, sourceWidth, sourceHeight, size);
  return { data: normalizeToNchw(rgb, size), meta };
}

/**
 * Map an xyxy box in the letterboxed frame (pixel units) back to normalized 0..1
 * coordinates over the original source image. Detections outside the content area
 * are clamped into the source image.
 *
 * On baked data (hold-bake output: 640x640 images, scale 1, zero pads) the meta
 * makes this a trivial identity: x / 640 over the baked frame, which is also the
 * source frame because the bake scaled and padded the boxes with the image.
 */
export function letterboxToSourceBox(box: readonly [number, number, number, number], meta: LetterboxMeta): SourceBox {
  const [x1, y1, x2, y2] = box;
  const clamp = (value: number, limit: number): number => Math.min(Math.max(value, 0), limit);
  return {
    x1: clamp((x1 - meta.padX) / meta.scale / meta.sourceWidth, 1),
    y1: clamp((y1 - meta.padY) / meta.scale / meta.sourceHeight, 1),
    x2: clamp((x2 - meta.padX) / meta.scale / meta.sourceWidth, 1),
    y2: clamp((y2 - meta.padY) / meta.scale / meta.sourceHeight, 1),
  };
}
