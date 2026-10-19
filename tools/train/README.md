# CyberSend hold detector training (D1)

Apache-2.0 stack only. No Ultralytics code or weights anywhere (AGPL, excluded by
decision 2026-10-19, see LICENSES.md and docs/decisions.md).

This directory builds the merged D1 dataset, trains the on-device hold detector
candidates (RF-DETR-Nano baseline plus a planned YOLOX-Nano comparison), and
exports the chosen model to ONNX with its license provenance. The Node eval
harness in tools/eval scores the export on the frozen COCO test split.

> ## WARNING: D1 training runs require explicit user approval
>
> Every training command below writes checkpoints of 500 MB and more and runs
> for many hours on the training host. Nothing in this README has been executed
> without the user's go-ahead, and nothing should be executed without it again.
> Data preparation (`hold-build`) and the harness stub run are not training and
> are safe to run. Ask before running `hold-train-d1`, YOLOX training, or any
> `uv run hold-train-smoke` invocation.

## Datasets

The D1 training data is `datasets/merged`, built from three Roboflow exports
(climbtag v29 CC BY 4.0, blackcreed v14 CC BY 4.0, pwals v18 CC BY 4.0, verified
2026-10-19), pHash deduplicated and resplit 60/20/20 at the cluster level
with the original Roboflow splits discarded. Sources, methodology, final
counts, the color sidecar, and known limitations live in DATASET_CARD.md; the
machine-readable record is `datasets/merged/manifest.json`.

```bash
cd tools/train
uv sync                 # create/refresh the venv from uv.lock
uv run hold-build       # merge + dedupe + resplit raw/ into merged/ (about 15 s)
uv run hold-build --force   # rebuild from scratch; deterministic, same digests
```

Merged dataset at a glance (see the manifest for authoritative digests):

| Split | Images | Annotations | Frozen |
|-------|--------|-------------|--------|
| train | 1,804 | 66,985 | no |
| val   | 591   | 22,782 | no |
| test  | 582   | 24,160 | yes |

Raw exports live under `datasets/raw/` (git-ignored, about 1 GB); the merged
output is about 290 MB. The shared `~/.roboflow` cache (pretrained weights,
about 349 MB) is kept outside this tree on purpose.

## Layout

```
tools/train/
  pyproject.toml          uv project, console scripts (hold-*), Apache-2.0
  uv.lock                 pinned dependency set (rfdetr 1.11.2, torch, onnxruntime)
  src/hold_train/         pipeline modules, one console script each
  configs/
    rf_detr_d1.yaml       D1 baseline run config (RF-DETR-Nano)
    yolox_d1.py           D1 comparison experiment (YOLOX-Nano, planned)
  datasets/               raw/ + merged/ (git ignored, re-creatable via hold-build)
  artifacts/              checkpoints, ONNX, manifests, logs (binaries git ignored)
  DATASET_CARD.md         dataset documentation (sources, method, counts, limits)
  LICENSES.md             license provenance record
tools/eval/
  src/preprocess.ts       shared inference preprocess (letterbox + normalize, pure TS)
  src/evaluate.ts         detector-agnostic eval core (preprocess, matching, metrics)
  src/detector.ts         Detector interface + OnnxDetector + StubDetector
  src/decode.ts           RF-DETR output decode (cxcywh + class logits)
  src/eval_hold.ts        ONNX eval harness (precision, recall, mAP@0.5, --gate)
  src/run_stub_eval.ts    end-to-end stub proof run (writes a labeled stub report)
  src/stub_fixture.ts     deterministic synthetic fixture generator
  src/*.test.ts           unit tests (node --test, no model required)
  reports/                eval report JSON (committed)
```

Console scripts (defined in pyproject.toml):

| Script | Module | What it does |
|--------|--------|--------------|
| hold-download | dataset_download.py | legacy Roboflow/HF downloader (raw data is already on disk for D1) |
| hold-convert | labelme_to_coco.py | labelme polygons to single-class COCO (own gym photos, US-5) |
| hold-split | split_dataset.py | seeded photo-level split with letterbox baking (own gym photos) |
| hold-build | build_dataset.py | merge + dedupe + resplit raw/ into datasets/merged (D1 dataset) |
| hold-train-smoke | train_smoke.py | parameterized RF-DETR-Nano trainer (kept for quick probes) |
| hold-train-d1 | train_d1.py | D1 baseline: reads configs/rf_detr_d1.yaml, trains RF-DETR-Nano |
| hold-export | export_onnx.py | checkpoint to ONNX opset 17 plus artifacts/manifest.json |

## D1 baseline run: RF-DETR-Nano

The run is fully specified by configs/rf_detr_d1.yaml (40 epochs, batch 4,
640 resolution, lr 1e-4, seed 20261019, device mps, output
artifacts/train_rf_detr_d1). hold-train-d1 reads the config, creates
`datasets/merged/valid` as a symlink to `val` (RF-DETR's Roboflow-style loader
expects the name "valid"), then calls RFDETRNano.train().

```bash
cd tools/train
mkdir -p artifacts
uv run hold-train-d1 --config configs/rf_detr_d1.yaml 2>&1 | tee artifacts/train_rf_detr_d1.log
```

### Expected wall time (Apple Silicon, MPS)

Measured anchor from the Phase 0 smoke run: RF-DETR-Nano at 640 px, batch 4,
about 2.8 s per training batch on M-series MPS, plus validation at roughly
2 images per second. Linear scaling to the merged dataset:

- train: 1,804 images, 451 batches of 4, about 21 minutes per epoch;
- validation: 591 images, about 5 minutes per epoch;
- total: about 26 minutes per epoch, so 40 epochs lands near 17 hours
  (honest range 15 to 22 hours; validation batching and MPS graph reuse vary).
  Check the first two epochs on screen and update this estimate rather than
  trusting the extrapolation.

Memory and thermals matter on this host: keep at least 8 GB RAM free with
other apps closed (the Phase 0 spike was killed twice under swap exhaustion),
and expect the machine to be unusable for other heavy work during the run.

### Expected disk per run

- checkpoint_best_ema.pth: about 500 to 600 MB (written on validation mAP
  improvement; RF-DETR 1.11.2 writes the EMA best),
- last.ckpt (Lightning): about 500 MB,
- metrics.csv and logs: negligible.

Keep about 3 GB free per run. Recommended keep-best-2 policy: let the run
write freely, then immediately prune to the two newest best checkpoints once
the run finishes:

```bash
cd artifacts/train_rf_detr_d1
ls -1 checkpoint*.pth last.ckpt        # inspect what the run produced
# after the run completed and the best checkpoint is exported:
rm last.ckpt                           # reclaim ~500 MB once export succeeded
```

### After the run: export and evaluate

```bash
cd tools/train
uv run hold-export \
  --checkpoint artifacts/train_rf_detr_d1/checkpoint_best_ema.pth \
  --output artifacts/holds_detector_d1.onnx \
  --manifest artifacts/manifest_d1.json \
  --dataset-dir datasets/merged

cd ../eval
npm install
npm run verify -- ../train/artifacts/holds_detector_d1.onnx
```

## Eval gates (Phase 4 quality, docs/requirements.md section 6)

Gate thresholds: precision >= 0.85 and recall >= 0.80 at IoU 0.5, mAP@0.5 >=
0.75, measured on the frozen test split at an operating confidence chosen on
the val split (never tuned on test).

```bash
cd tools/eval

# 1. Choose the operating threshold on the val split.
npm run eval -- --model ../train/artifacts/holds_detector_d1.onnx \
  --split-dir ../train/datasets/merged/val \
  --report reports/d1_val_eval.json --confidence 0.5

# 2. Re-run on the frozen test split with the chosen threshold and the gates.
#    --gate exits 3 when any of precision/recall/mAP50 misses its floor.
npm run eval -- --model ../train/artifacts/holds_detector_d1.onnx \
  --split-dir ../train/datasets/merged/test \
  --report reports/d1_test_eval.json --confidence <chosen> --gate
```

Secondary Phase 4 numerics (median absolute hold-count error <= 1.0, false
positives per image <= 0.5) are reported in the same JSON. Proxy-domain gates
passing does NOT satisfy Phase 4 acceptance: the frozen self-collected test
set from US-5 must also be evaluated (see DATASET_CARD.md, "Adding the user's
own gym photos").

The harness itself is proven code-complete without a model:

```bash
cd tools/eval
npm test           # unit tests incl. end-to-end stub evaluation
npm run eval:stub  # stub detector run; writes reports/stub_eval.json, labeled STUB
```

## D1 comparison run: YOLOX-Nano (planned, not executed)

Apache-2.0 Megvii YOLOX only, exp file configs/yolox_d1.py (40 epochs, batch 8,
640 px, num_classes 1, same seed). The yolox package is deliberately not a
project dependency; install it in an isolated environment only when this run is
approved. Expect to adapt device handling: Megvii YOLOX targets CUDA, and MPS
support is unverified, so this run may fall back to CPU (3 to 5 times slower,
roughly 1 to 3 days at batch 8) or need a small device patch; resolve that
before committing to the run. Estimated epoch time on MPS if it works: 8 to 15
minutes, so 40 epochs in the 6 to 10 hour range.

YOLOX loads COCO data as `data_dir/<split>/<file_name>` with the annotation
JSONs under `data_dir/annotations/`. Create the symlink adapter once:

```bash
cd tools/train/datasets
mkdir -p merged_yolox/annotations
ln -sfn ../merged/train             merged_yolox/train2017
ln -sfn ../merged/val               merged_yolox/val2017
ln -sfn ../../merged/train/_annotations.coco.json  merged_yolox/annotations/instances_train2017.json
ln -sfn ../../merged/val/_annotations.coco.json    merged_yolox/annotations/instances_val2017.json
```

Then, in the isolated environment with yolox installed:

```bash
python -m yolox.tools.train -f configs/yolox_d1.py -b 8 -c <apache2.0-yolox-nano-pretrained.pt>
```

Comparison protocol: export both models to ONNX, evaluate both on the same
frozen test split with the same harness, and record precision, recall, mAP@0.5,
latency, and export size in docs/research.md before picking the Phase 4 model.

## Preprocess parity with the app

Inference preprocess (letterbox 640 pad 114 centered, RGB float32 NCHW,
ImageNet normalization) lives once in tools/eval/src/preprocess.ts as pure
typed-array code, per docs/architecture.md. The eval harness maps ground truth
into the letterboxed frame with the same geometry, so raw-resolution test
images are handled correctly. The Phase 4 app path
(src/features/ml/preprocess.ts) must reuse the same contract so eval numbers
transfer to on-device behavior.

## Troubleshooting

### Harness mAP vs RF-DETR in-loop validation mAP (open reconciliation item)

Recorded in tools/eval/reports/smoke_eval.json: RF-DETR's in-loop validation
mAP@50 logged during the Phase 0 smoke run was higher than what the Node
harness computes on the same split with standard single-class AP@0.5 semantics.
Harness correctness was verified directly on that run (preprocess parity with
RF-DETR's Normalize transform, ONNX boxes within a few pixels of torch
predict). The remaining difference is a metric-semantics question (checkpoint
selection uses RF-DETR's in-loop metric, the Phase 4 gate uses the harness
metric), and it must be reconciled or explicitly documented as an accepted
offset before D1 gate numbers are treated as authoritative.

## History note

The Phase 0 smoke spike (ClimbInst subset, CC BY-NC-SA 4.0, smoke checkpoint,
smoke ONNX) was retired on 2026-10-19: its dataset and artifacts were deleted
when the merged D1 dataset landed. tools/eval/reports/smoke_eval.json remains
only as a historical record of that spike and references artifacts that no
longer exist; it gates nothing. The memory-pressure lessons from that spike
(RAM headroom, swap exhaustion kills) still apply to D1 runs.
