/**
 * Verify that the exported hold detector ONNX loads in onnxruntime-node and runs one
 * dummy inference. Prints the observed input/output contract so it can be diffed
 * against tools/train/artifacts/manifest.json.
 *
 * Usage: node src/verify_onnx.ts [path/to/model.onnx]
 */

import path from "node:path";
import { fileURLToPath } from "node:url";

import * as ort from "onnxruntime-node";

import { TARGET_SIZE } from "./preprocess.ts";

const EVAL_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const DEFAULT_MODEL = path.resolve(EVAL_ROOT, "..", "train", "artifacts", "holds_detector_d1.onnx");

async function main(): Promise<void> {
  const modelPath = path.resolve(process.argv[2] ?? DEFAULT_MODEL);
  console.log(`Loading ${modelPath}`);
  const session = await ort.InferenceSession.create(modelPath);
  console.log(`inputs: ${JSON.stringify(session.inputNames)}`);
  console.log(`outputs: ${JSON.stringify(session.outputNames)}`);

  for (const input of session.inputMetadata) {
    if ("shape" in input) {
      console.log(`input ${input.name}: type=${input.type} dims=${JSON.stringify(input.shape)}`);
    }
  }
  for (const output of session.outputMetadata) {
    if ("shape" in output) {
      console.log(`output ${output.name}: type=${output.type} dims=${JSON.stringify(output.shape)}`);
    }
  }

  const inputName = session.inputNames[0];
  if (inputName === undefined) {
    throw new Error("model has no inputs");
  }

  // Dummy inference: a letterbox-gray canvas (114) is closer to real inputs than zeros.
  const dummy = new Float32Array(3 * TARGET_SIZE * TARGET_SIZE);
  dummy.fill(114 / 255);
  const tensor = new ort.Tensor("float32", dummy, [1, 3, TARGET_SIZE, TARGET_SIZE]);

  const start = performance.now();
  const results = await session.run({ [inputName]: tensor });
  const elapsed = performance.now() - start;

  for (const [name, value] of Object.entries(results)) {
    const data = value.data as Float32Array;
    let min = Number.POSITIVE_INFINITY;
    let max = Number.NEGATIVE_INFINITY;
    for (const element of data) {
      if (element < min) min = element;
      if (element > max) max = element;
    }
    console.log(
      `output ${name}: dims=${JSON.stringify(value.dims)} values=${data.length} min=${min.toFixed(5)} max=${max.toFixed(5)} (${elapsed.toFixed(1)} ms)`,
    );
  }
  console.log("verify_onnx: OK");
}

main().catch((error: unknown) => {
  console.error("verify_onnx: FAILED", error);
  process.exitCode = 1;
});
