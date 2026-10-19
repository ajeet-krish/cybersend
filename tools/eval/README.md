# CyberSend hold detector eval harness (Node)

Standalone npm package that runs an exported hold detector ONNX with
onnxruntime-node over a frozen COCO split and computes single-class detection
metrics at IoU 0.5: precision, recall at the declared operating confidence, and
mAP@0.5, plus the Phase 4 secondary numerics (false positives per image,
median absolute hold-count error). Writes a JSON report to reports/.

The harness is detector-agnostic at its core (src/evaluate.ts) and proven
code-complete without any model: a stub detector runs the full pipeline
(decode, preprocess, matching, metrics, report) over a deterministic synthetic
fixture, with unit tests covering the pure pieces.

## Commands

```bash
cd tools/eval
npm install

# Unit tests, including the end-to-end stub evaluation. No model needed.
npm test

# End-to-end stub run; writes reports/stub_eval.json clearly labeled STUB.
npm run eval:stub

# Evaluate a real export (needs the ONNX from a training run).
npm run eval -- --model ../train/artifacts/holds_detector_d1.onnx \
  --split-dir ../train/datasets/merged/test --report reports/d1_test_eval.json \
  --confidence 0.5

# Same, plus the Phase 4 gates (exits 3 when precision/recall/mAP50 miss their
# floors: 0.85 / 0.80 / 0.75 per docs/requirements.md section 6).
npm run eval -- --model ../train/artifacts/holds_detector_d1.onnx \
  --split-dir ../train/datasets/merged/test --report reports/d1_test_eval.json \
  --confidence <chosen-on-val> --gate

# Load an ONNX, print the input/output contract, run one dummy inference.
npm run verify -- ../train/artifacts/holds_detector_d1.onnx

# Type check (Node 22.18+ runs the TypeScript directly via type stripping).
npm run typecheck
```

Flags for npm run eval (all optional): --model, --split-dir (alias
--test-dir), --report, --confidence (operating threshold, default 0.5), --iou
(default 0.5), --score-floor (default 1e-4), --gate, --label.

## Layout

- src/preprocess.ts: the shared inference preprocess contract (letterbox 640,
  pad 114 centered, RGB float32 NCHW, ImageNet normalization), pure typed
  arrays, no native imports. Kept in lockstep with the app path
  src/features/ml/preprocess.ts per docs/architecture.md.
- src/evaluate.ts: detector-agnostic eval core. Ground truth boxes live in
  source pixels and are mapped into the letterboxed frame with the same
  geometry the model sees, so raw-resolution test images work directly.
- src/metrics.ts: greedy confidence-ordered matching, IoU, VOC 2010+ all-point
  AP (precision envelope via suffix maxima).
- src/detector.ts: Detector interface; OnnxDetector (onnxruntime-node, no NMS,
  DETR-style raw queries) and StubDetector (oracle/noop, deterministic jitter).
- src/decode.ts: RF-DETR output decode (dets = normalized cxcywh, labels =
  num_classes + 1 logits where channel 0 is the hold score and the trailing
  channel is no-object).
- src/eval_hold.ts: harness main with report writing and the --gate check.
- src/run_stub_eval.ts: code-complete proof run against the stub detector.
- src/stub_fixture.ts: deterministic synthetic fixture generator (JPEGs +
  COCO JSON, no committed binaries).
- src/*.test.ts: node --test unit tests.
- reports/: committed eval reports (stub_eval.json is labeled STUB and proves
  the harness only; smoke_eval.json is a historical Phase 0 record whose model
  artifact was deleted).

## Preprocess parity

The preprocess here is the single source of truth shared with the app. For
raw photos it produces the model input and the letterbox meta used to map
detections back to normalized 0..1 source coordinates via
letterboxToSourceBox, which is the contract the Phase 4 app must reuse.
