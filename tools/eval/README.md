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

# Unit tests, including the end-to-end stub evaluation, the test split policy,
# and baked dataset parity. No model needed.
npm test

# End-to-end stub run; writes reports/stub_eval.json clearly labeled STUB.
npm run eval:stub

# Evaluate a real export on the DEFAULT split (val; needs the ONNX from a
# training run). Model selection and threshold tuning happen here, never on test.
npm run eval -- --model ../train/artifacts/holds_detector_d1.onnx \
  --split-dir ../train/datasets/merged/val \
  --report reports/d1_val_eval.json --confidence 0.5

# Same harness for the YOLOX export (raw 0..255 input, NMS applied here because
# the graph has none). --model-kind defaults to auto, which reads the output
# names; passing it explicitly removes any doubt.
npm run eval -- --model ../train/artifacts/holds_detector_yolox_d1.onnx \
  --model-kind yolox --split-dir ../train/datasets/merged/val \
  --report reports/d1_val_eval_yolox.json --confidence 0.5

# The ONE gated test run: scoring the frozen test split requires the explicit
# --i-accept-one-test-run flag (without it the harness refuses with exit 2
# before loading the model) and appends a line to reports/test_ledger.jsonl
# (timestamp, model id, report path, git describe). --gate exits 3 when
# precision/recall/mAP50 miss their floors: 0.85 / 0.80 / 0.75 per
# docs/requirements.md section 6.
npm run eval -- --model ../train/artifacts/holds_detector_d1.onnx \
  --split-dir ../train/datasets/merged/test \
  --report reports/d1_test_eval.json --confidence <chosen-on-val> --gate \
  --i-accept-one-test-run

# Load an ONNX, print the input/output contract, run one dummy inference.
npm run verify -- ../train/artifacts/holds_detector_d1.onnx

# False positive anatomy at an operating point: splits the false positives into
# duplicate, near miss, loose, and background buckets, then sweeps dedupe IoU,
# minimum box area, and the frame edge filter. --dump-fps writes every false
# positive with its image, box, score, and bucket so the boxes can be cropped
# into a contact sheet and inspected by eye. Val only; it never scores test.
npm run analyze:fp -- --model ../train/artifacts/holds_detector_d1.onnx \
  --split-dir ../train/datasets/merged/val --confidence 0.765 \
  --report reports/fp_rfdetr_d1.json --dump-fps reports/fp_rfdetr_d1_boxes.json

# Type check (Node 22.18+ runs the TypeScript directly via type stripping).
npm run typecheck
```

Flags for npm run analyze:fp (all optional): --model, --model-kind
(auto|rfdetr|yolox), --split-dir, --confidence, --iou, --report, --dump-fps.

Flags for npm run eval (all optional): --model, --model-kind
(auto|rfdetr|yolox, default auto), --split-dir (alias --test-dir, default
../train/datasets/merged/val), --report (defaults to reports/d1_val_eval.json,
or d1_test_eval.json for a test split), --confidence (operating threshold,
default 0.5), --iou (default 0.5), --score-floor (default 1e-4), --gate,
--label, --i-accept-one-test-run.

## One gated test run policy

The frozen test split may be scored exactly once per model iteration, and only
deliberately:

- a split directory counts as the test split when its final path segment is
  `test`;
- scoring it without `--i-accept-one-test-run` fails fast with exit code 2,
  before any model or data loads;
- every accepted run appends one JSON line to `reports/test_ledger.jsonl` with
  the timestamp, model id (from the export manifest when present), report path,
  and `git describe` when git is available, plus the split, confidence, and
  whether `--gate` was requested;
- the ledger line is written BEFORE scoring, so even a run that dies midway is
  on the record;
- `--gate` behavior is unchanged: exit 3 below the Phase 4 floors.

The policy lives in src/test_policy.ts (unit tested); the val split, stub runs,
and `npm run eval:stub` never touch the ledger.

## Layout

- src/preprocess.ts: the shared inference preprocess contract (letterbox 640,
  pad 114 centered, RGB float32 NCHW), pure typed arrays, no native imports.
  Two value modes: "imagenet" (RF-DETR) and "raw" (YOLOX, 0..255). Kept in
  lockstep with the app path src/features/ml/preprocess.ts per
  docs/architecture.md.
- src/evaluate.ts: detector-agnostic eval core. The detector declares its
  preprocess mode and the core encodes the tensor accordingly. Ground truth
  boxes live in image pixels and are mapped into the letterboxed frame with the
  same geometry the model sees; on baked data (hold-bake) that mapping is an
  identity, so raw-resolution splits and baked splits both work directly.
- src/metrics.ts: greedy confidence-ordered matching, IoU, VOC 2010+ all-point
  AP (precision envelope via suffix maxima).
- src/detector.ts: Detector interface; OnnxDetector (onnxruntime-node, kind
  rfdetr or yolox, auto-detected from output names) and StubDetector
  (oracle/noop, deterministic jitter).
- src/decode.ts: RF-DETR output decode (dets = normalized cxcywh, labels =
  num_classes + 1 logits where channel 0 is the hold score and the trailing
  channel is no-object).
- src/decode_yolox.ts: YOLOX output decode (cxcywh pixels to clipped xyxy,
  score = objectness times best class, then class-agnostic greedy NMS at IoU
  0.65 over anchors scoring at least 0.01, the COCO convention used during
  training).
- src/eval_hold.ts: harness main with report writing, the --gate check, and the
  test split guard (exit 2 without --i-accept-one-test-run).
- src/test_policy.ts: one gated test run policy (split detection, acceptance
  check, ledger entry format, git describe) as pure testable logic.
- src/run_stub_eval.ts: code-complete proof run against the stub detector.
- src/stub_fixture.ts: deterministic synthetic fixture generator (JPEGs +
  COCO JSON, no committed binaries).
- src/*.test.ts: node --test unit tests, including baked_parity.test.ts (baked
  image + harness letterbox round trip), test_policy.test.ts, and
  yolox_decode.test.ts (cxcywh decode, clipping, NMS, raw preprocess mode).
- reports/: committed eval reports (stub_eval.json is labeled STUB and proves
  the harness only; smoke_eval.json is a historical Phase 0 record whose model
  artifact was deleted; val_rfdetr_d1.json and val_yolox_d1.json are the D1 val
  comparisons; d1_test_eval.json is the single gated frozen-test run;
  test_ledger.jsonl grows by one line per accepted test split run).

## Preprocess parity

The preprocess here is the single source of truth shared with the app. For
raw photos it produces the model input and the letterbox meta used to map
detections back to normalized 0..1 source coordinates via
letterboxToSourceBox, which is the contract the Phase 4 app must reuse.

The merged D1 dataset ships already letterboxed by tools/train hold-bake
(640x640, pad 114, centered, boxes transformed with the image). On that data
letterboxRgba is an exact identity (scale 1, zero pads, no resampling) and
letterboxToSourceBox reduces to x / 640 over the baked frame;
baked_parity.test.ts asserts both against the real baked val split when it
exists on disk.
