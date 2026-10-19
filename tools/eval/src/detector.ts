/**
 * Detector abstraction for the eval harness.
 *
 * The harness core (evaluate.ts) is detector-agnostic: it letterboxes each test
 * image into the shared preprocess contract and asks a Detector for
 * detections in the letterboxed frame. Two implementations exist:
 *
 *   - OnnxDetector: the real path, onnxruntime-node plus the RF-DETR decode
 *     in decode.ts. No NMS: RF-DETR is a DETR-style set predictor and is
 *     evaluated on its raw per-query outputs.
 *   - StubDetector: deterministic fake detections used by the unit tests and
 *     the end-to-end stub run, so the harness is provably code-complete before
 *     any real model exists.
 */

import * as ort from "onnxruntime-node";

import { decodeOutputs } from "./decode.ts";
import { TARGET_SIZE } from "./preprocess.ts";

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
  /** input is the float32 NCHW tensor data (length 3 * TARGET_SIZE * TARGET_SIZE). */
  detect(input: Float32Array, context: DetectorContext): Promise<DetectorDetection[]>;
}

/** Real detector: an RF-DETR ONNX export run through onnxruntime-node. */
export class OnnxDetector implements Detector {
  readonly name: string;
  private readonly session: ort.InferenceSession;
  private readonly inputName: string;

  private constructor(session: ort.InferenceSession, modelPath: string) {
    this.session = session;
    this.name = `onnx:${modelPath}`;
    const inputName = session.inputNames[0];
    if (inputName === undefined) {
      throw new Error("model has no inputs");
    }
    this.inputName = inputName;
  }

  static async create(modelPath: string): Promise<OnnxDetector> {
    const session = await ort.InferenceSession.create(modelPath);
    return new OnnxDetector(session, modelPath);
  }

  async detect(input: Float32Array): Promise<DetectorDetection[]> {
    const tensor = new ort.Tensor("float32", input, [1, 3, TARGET_SIZE, TARGET_SIZE]);
    const results = await this.session.run({ [this.inputName]: tensor });
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
