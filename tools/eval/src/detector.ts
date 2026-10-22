/**
 * Detector abstraction for the eval harness.
 *
 * The harness core (evaluate.ts) is detector-agnostic: it asks each Detector
 * which preprocess contract it needs, letterboxes and encodes the image
 * accordingly, then asks for detections in the letterboxed frame. Two real
 * paths exist plus a stub:
 *
 *   - OnnxDetector with kind "rfdetr": onnxruntime-node plus the RF-DETR
 *     decode in decode.ts. No NMS: RF-DETR is a DETR-style set predictor and
 *     is evaluated on its raw per-query outputs.
 *   - OnnxDetector with kind "yolox": onnxruntime-node plus the YOLOX decode in
 *     decode_yolox.ts, which converts cxcywh pixels to xyxy and applies NMS
 *     (the YOLOX graph has no NMS).
 *   - StubDetector: deterministic fake detections used by the unit tests and
 *     the end-to-end stub run, so the harness is provably code-complete before
 *     any real model exists.
 */

import * as ort from "onnxruntime-node";

import { decodeOutputs } from "./decode.ts";
import {
  decodeYoloxOutputs,
  nmsIndices,
  YOLOX_NMS_IOU,
  YOLOX_PRE_NMS_FLOOR,
} from "./decode_yolox.ts";
import { TARGET_SIZE, type PreprocessMode } from "./preprocess.ts";

/** Which exported model contract an OnnxDetector speaks. */
export type ModelKind = "rfdetr" | "yolox";

/** One detection in pixels of the letterboxed TARGET_SIZE x TARGET_SIZE frame. */
export interface DetectorDetection {
  readonly x1: number;
  readonly y1: number;
  readonly x2: number;
  readonly y2: number;
  readonly score: number;
}

export interface DetectorContext {
  /** Base file name of the source image, for detector-internal bookkeeping. */
  readonly fileName: string;
}

export interface Detector {
  readonly name: string;
  /** Tensor contract the harness must use when building the input tensor. */
  readonly preprocess: PreprocessMode;
  /** input is the float32 NCHW tensor data (length 3 * TARGET_SIZE * TARGET_SIZE). */
  detect(input: Float32Array, context: DetectorContext): Promise<DetectorDetection[]>;
}

/** Identify a model from its output names, the contract both exports declare. */
function inferModelKind(session: ort.InferenceSession): ModelKind {
  const names = [...session.outputNames].sort();
  if (names.length === 2 && names[0] === "dets" && names[1] === "labels") {
    return "rfdetr";
  }
  if (names.length === 1 && names[0] === "output") {
    return "yolox";
  }
  throw new Error(
    `cannot infer model kind from outputs [${session.outputNames.join(", ")}]; pass --model-kind`,
  );
}

/** Real detector: an ONNX export run through onnxruntime-node. */
export class OnnxDetector implements Detector {
  readonly name: string;
  readonly kind: ModelKind;
  readonly preprocess: PreprocessMode;
  private readonly session: ort.InferenceSession;
  private readonly inputName: string;

  private constructor(session: ort.InferenceSession, modelPath: string, kind: ModelKind) {
    this.session = session;
    this.kind = kind;
    this.preprocess = kind === "yolox" ? "raw" : "imagenet";
    this.name = `onnx:${modelPath}`;
    const inputName = session.inputNames[0];
    if (inputName === undefined) {
      throw new Error("model has no inputs");
    }
    this.inputName = inputName;
  }

  static async create(modelPath: string, kind: ModelKind | "auto" = "auto"): Promise<OnnxDetector> {
    const session = await ort.InferenceSession.create(modelPath);
    const resolved = kind === "auto" ? inferModelKind(session) : kind;
    return new OnnxDetector(session, modelPath, resolved);
  }

  async detect(input: Float32Array): Promise<DetectorDetection[]> {
    const tensor = new ort.Tensor("float32", input, [1, 3, TARGET_SIZE, TARGET_SIZE]);
    const results = await this.session.run({ [this.inputName]: tensor });
    return this.kind === "yolox" ? decodeYolox(results) : decodeRfDetr(results);
  }
}

function decodeRfDetr(results: Readonly<Record<string, ort.Tensor>>): DetectorDetection[] {
  const { boxes, scores, numQueries } = decodeOutputs(results);
  const detections: DetectorDetection[] = [];
  for (let query = 0; query < numQueries; query += 1) {
    const score = scores[query] ?? 0;
    const cx = (boxes[query * 4] ?? 0) * TARGET_SIZE;
    const cy = (boxes[query * 4 + 1] ?? 0) * TARGET_SIZE;
    const boxWidth = (boxes[query * 4 + 2] ?? 0) * TARGET_SIZE;
    const boxHeight = (boxes[query * 4 + 3] ?? 0) * TARGET_SIZE;
    detections.push({
      score,
      x1: cx - boxWidth / 2,
      y1: cy - boxHeight / 2,
      x2: cx + boxWidth / 2,
      y2: cy + boxHeight / 2,
    });
  }
  return detections;
}

function decodeYolox(results: Readonly<Record<string, ort.Tensor>>): DetectorDetection[] {
  const { boxes, scores, numAnchors } = decodeYoloxOutputs(results, TARGET_SIZE);
  const kept = nmsIndices(boxes, scores, numAnchors, YOLOX_NMS_IOU, YOLOX_PRE_NMS_FLOOR);
  return kept.map((index) => ({
    score: scores[index] ?? 0,
    x1: boxes[index * 4] ?? 0,
    y1: boxes[index * 4 + 1] ?? 0,
    x2: boxes[index * 4 + 2] ?? 0,
    y2: boxes[index * 4 + 3] ?? 0,
  }));
}

export type StubMode = "oracle" | "noop";

export interface StubOptions {
  readonly mode: StubMode;
  /** Boxes per file name in letterboxed-frame pixels, required for oracle mode. */
  readonly boxesByFile?: ReadonlyMap<string, Array<{ x1: number; y1: number; x2: number; y2: number }>>;
  /** Deterministic jitter amplitude in pixels; 0 disables jitter. */
  readonly jitterPx?: number;
  readonly score?: number;
}

/** Deterministic 32-bit hash used to derive per-image jitter without randomness. */
function stableHash(text: string): number {
  let hash = 2166136261;
  for (let index = 0; index < text.length; index += 1) {
    hash ^= text.charCodeAt(index);
    hash = Math.imul(hash, 16777619);
  }
  return hash >>> 0;
}

/**
 * Stub detector for tests and the code-complete harness proof.
 *
 * Oracle mode returns each image's known boxes with a small deterministic
 * jitter derived from the file name, so an end-to-end harness run over a
 * fixture must produce precision, recall, and mAP of 1.0 at IoU 0.5 (jitter
 * stays far below the matching threshold). Noop mode returns zero
 * detections.
 */
export class StubDetector implements Detector {
  readonly name: string;
  readonly preprocess: PreprocessMode = "imagenet";
  private readonly options: StubOptions;

  constructor(options: StubOptions) {
    this.options = options;
    this.name = `stub:${options.mode}`;
  }

  async detect(_input: Float32Array, context: DetectorContext): Promise<DetectorDetection[]> {
    if (this.options.mode === "noop") {
      return [];
    }
    const boxes = this.options.boxesByFile?.get(context.fileName);
    if (boxes === undefined) {
      throw new Error(`stub oracle has no boxes for ${context.fileName}`);
    }
    const jitter = this.options.jitterPx ?? 0;
    const score = this.options.score ?? 0.9;
    return boxes.map((box, index) => {
      const seed = stableHash(`${context.fileName}:${index}`);
      const dx = jitter === 0 ? 0 : ((seed & 7) - 3.5) * (jitter / 3.5);
      const dy = jitter === 0 ? 0 : (((seed >> 8) & 7) - 3.5) * (jitter / 3.5);
      return {
        x1: box.x1 + dx,
        y1: box.y1 + dy,
        x2: box.x2 + dx,
        y2: box.y2 + dy,
        score,
      };
    });
  }
}
