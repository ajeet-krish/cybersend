/**
 * RF-DETR output decode: raw ONNX tensors to hold scores and boxes.
 *
 * The exported head emits, per query:
 *   - a box tensor [1, num_queries, 4] of normalized cxcywh in 0..1 over the
 *     letterboxed frame, and
 *   - a logits tensor [1, num_queries, num_classes + 1] where the trailing
 *     channel is the no-object class (rfdetr models/lwdetr.py heads are
 *     num_classes + 1 wide). Channel 0 is the "hold" score; independent
 *     sigmoid, no softmax.
 *
 * This module is RF-DETR-specific; the harness core in evaluate.ts only sees
 * plain letterboxed-frame detections via the Detector interface.
 */

import type * as ort from "onnxruntime-node";

export interface DecodedOutputs {
  /** Normalized cxcywh boxes, length numQueries * 4. */
  readonly boxes: Float32Array;
  /** Hold scores (sigmoid applied), length numQueries. */
  readonly scores: Float32Array;
  readonly numQueries: number;
}

/** Convert RF-DETR raw outputs (normalized cxcywh boxes + logits) into hold scores. */
export function decodeOutputs(results: Readonly<Record<string, ort.Tensor>>): DecodedOutputs {
  let boxes: Float32Array | undefined;
  let logits: Float32Array | undefined;
  let numQueries = 0;
  for (const value of Object.values(results)) {
    const dims = value.dims;
    if (dims.length === 3 && dims[2] === 4) {
      boxes = value.data as Float32Array;
      numQueries = dims[1] ?? 0;
    } else if (dims.length === 3) {
      logits = value.data as Float32Array;
    }
  }
  if (boxes === undefined || logits === undefined || numQueries <= 0) {
    throw new Error(`unexpected model outputs: ${Object.keys(results).join(", ")}`);
  }
  const numChannels = logits.length / numQueries;
  if (!Number.isInteger(numChannels) || numChannels < 1) {
    throw new Error(`logit tensor length ${logits.length} not divisible by ${numQueries} queries`);
  }
  const scores = new Float32Array(numQueries);
  for (let query = 0; query < numQueries; query += 1) {
    const holdLogit = logits[query * numChannels] ?? 0;
    scores[query] = 1 / (1 + Math.exp(-holdLogit));
  }
  return { boxes, scores, numQueries };
}
