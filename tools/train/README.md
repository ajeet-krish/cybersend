# CyberSend hold detector training (D1)

Apache-2.0 stack only. No Ultralytics code or weights anywhere (AGPL, excluded by
decision 2026-10-19, see LICENSES.md and docs/decisions.md).

This directory builds the merged D1 dataset, trains the on-device hold detector
candidates (RF-DETR-Nano baseline plus an approved YOLOX-Nano comparison), and
exports the chosen model to ONNX with its license provenance. The Node eval
harness in tools/eval scores the export on the val split by default and, under
the one gated test run policy, once on the frozen COCO test split.

> ## WARNING: D1 training runs require explicit user approval
>
> Every training command below writes checkpoints of 500 MB and more and runs
> for many hours on the training host. Nothing in this README has been executed
> without the user's go-ahead, and nothing should be executed without it again.
> Data preparation (`hold-build`, `hold-bake`, `hold-bake --verify`), the Python
> unit tests, and the harness stub run are not training and are safe to run.
> Ask before running `hold-train-d1` (INCLUDING the 1-epoch preflight, which is
> a training run), YOLOX training, or any `uv run hold-train-smoke` invocation.

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
uv run hold-bake            # bake letterbox-640 into merged/ images + boxes
uv run hold-bake --verify   # re-check the baked dataset, writes nothing
uv run python -m unittest discover -s tests -v   # bake + geometry unit tests
```

### Letterbox bake (hold-bake)

`hold-build` writes source-resolution images with boxes in source pixels;
`hold-bake` rewrites `datasets/merged` in place so the shared inference
preprocess is part of the data:

- every image becomes 640x640 RGB JPEG (pad value 114, aspect ratio preserved,
  padding centered, BICUBIC), with the geometry byte-consistent with
  `tools/eval/src/preprocess.ts` (JavaScript half-up rounding of the content
  size, `floor` pad offsets);
- every bbox is scaled by the letterbox scale, offset by the pad, clipped to
  the canvas, rounded to 2 decimals; boxes under 2 px after the transform are
  dropped and counted (93 dropped total: train 54, val 20, test 19; 0 clipped
  because `hold-build` already clipped to source bounds);
- image records keep `source_width`, `source_height`, `letterbox_scale`,
  `letterbox_pad_x`, `letterbox_pad_y`, so the transform stays auditable;
- the pwals color sidecar boxes are transformed with their image
  (1,514 boxes to 1,510, 4 degenerate dropped);
- `manifest.json` gains a `bake` section, and the split
  `annotations_sha256` digests become POST-bake digests (a rebuild, or any bake
  that transforms boxes, changes the annotation SHA256s; split membership
  including the frozen test split is unchanged).

Once baked, the harness letterbox on merged data is an exact identity (scale 1,
zero pads, no resampling), RF-DETR's `Resize((640, 640))` eval transform is an
identity too, and detections, ground truth, and app preprocessing all live in
one frame. `hold-bake` is idempotent: a second pass changes no image or
annotation bytes and keeps the original bake record in the manifest.
Unit tests: `uv run python -m unittest discover -s tests -v`, plus the harness
parity tests `baked_parity.test.ts` in `tools/eval`.

Merged dataset at a glance (baked, see the manifest for authoritative digests):

| Split | Images | Annotations (baked) | Frozen |
|-------|--------|---------------------|--------|
| train | 1,804 | 66,931 | no |
| val   | 591   | 22,762 | no |
| test  | 582   | 24,141 | yes |

Raw exports live under `datasets/raw/` (git-ignored, about 1.0 GB); the merged
output is about 240 MB after the bake (about 290 MB at source resolution
before). The shared `~/.roboflow` cache (pretrained weights, about 349 MB) is
kept outside this tree on purpose.

## Layout

```
tools/train/
  pyproject.toml          uv project, console scripts (hold-*), Apache-2.0
  uv.lock                 pinned dependency set (rfdetr 1.11.2, torch, onnxruntime)
  src/hold_train/         pipeline modules, one console script each
  tests/                  Python unit tests (bake geometry, box transform, round trip)
  configs/
    rf_detr_d1.yaml       D1 baseline run config (RF-DETR-Nano, 40 epochs)
    rf_detr_d1_preflight.yaml  D1 1-epoch preflight config (batch 2, approval required)
    rf_detr_d1_lowmem.yaml     D1 low-memory run config (batch 2, multi-scale off)
    rf_detr_d1_lowmem_resume.yaml  resume config for an interrupted lowmem run
    yolox_d1.py           D1 comparison experiment (YOLOX-Nano, approved 2026-10-20)
    yolox_mps_microcheck.py     5-check MPS patch sanity run (seconds, no dataset)
  patches/                committed device patch applied to the isolated yolox install
  datasets/               raw/ + merged/ (git ignored, re-creatable via hold-build + hold-bake)
  artifacts/              checkpoints, ONNX, manifests, logs (binaries git ignored)
  DATASET_CARD.md         dataset documentation (sources, method, counts, limits)
  LICENSES.md             license provenance record
tools/eval/
  src/preprocess.ts       shared inference preprocess (letterbox + normalize, pure TS)
  src/evaluate.ts         detector-agnostic eval core (preprocess, matching, metrics)
  src/detector.ts         Detector interface + OnnxDetector + StubDetector
  src/decode.ts           RF-DETR output decode (cxcywh + class logits)
  src/eval_hold.ts        ONNX eval harness (precision, recall, mAP@0.5, --gate)
  src/test_policy.ts      one gated test run policy (test split guard + ledger entry)
  src/run_stub_eval.ts    end-to-end stub proof run (writes a labeled stub report)
  src/stub_fixture.ts     deterministic synthetic fixture generator
  src/*.test.ts           unit tests (node --test, no model required)
  reports/                eval report JSON (committed), test_ledger.jsonl (one line per test run)
```

Console scripts (defined in pyproject.toml):

| Script | Module | What it does |
|--------|--------|--------------|
| hold-download | dataset_download.py | legacy Roboflow/HF downloader (raw data is already on disk for D1) |
| hold-convert | labelme_to_coco.py | labelme polygons to single-class COCO (own gym photos, US-5) |
| hold-split | split_dataset.py | seeded photo-level split with letterbox baking (own gym photos) |
| hold-build | build_dataset.py | merge + dedupe + resplit raw/ into datasets/merged (D1 dataset) |
| hold-bake | bake_dataset.py | bake letterbox-640 into datasets/merged images and boxes; `--verify` re-checks |
| hold-train-smoke | train_smoke.py | parameterized RF-DETR-Nano trainer (kept for quick probes) |
| hold-train-d1 | train_d1.py | D1 baseline: reads configs/rf_detr_d1.yaml, trains RF-DETR-Nano |
| hold-export | export_onnx.py | checkpoint to ONNX opset 17 plus artifacts/manifest.json (`--id`, `--version`, `--purpose`) |

## D1 preflight: one epoch (REQUIRES USER APPROVAL BEFORE RUNNING)

> **REQUIRES USER APPROVAL BEFORE RUNNING.** A 1-epoch preflight IS a training
> run: it writes checkpoints of about 500 MB and occupies the host for roughly
> 30 minutes. It has NOT been executed. Ask the user first.

Purpose: prove the D1 plumbing end to end before committing to the 40 epoch
run, using `configs/rf_detr_d1_preflight.yaml` (1 epoch, batch 2, merged data,
device mps, seed 20261019). It validates:

- **config keys**: `dataset_dir`, `output_dir`, `model`, `train`, `device`,
  `seed` are all required by `hold-train-d1`, and `device`/`seed` are forwarded
  verbatim to `RFDETRNano.train()` (same passthrough the smoke run proves);
- **category id**: every merged annotation uses category id 1 (`hold`), zero
  occurrences of id 0, enforced by the `hold-build` sanity check and
  `hold-bake --verify`;
- **symlink**: `hold-train-d1` creates `datasets/merged/valid` as a symlink to
  `val` for RF-DETR's Roboflow-style loader (recreated after every rebuild);
- **checkpoint naming**: expect `checkpoint_best_ema.pth` (RF-DETR 1.11.2 best
  by validation mAP) and `last.ckpt` in `artifacts/train_rf_detr_d1_preflight`;
- **export kwargs**: `hold-export` takes `--id`, `--version`, `--purpose` and
  reads dataset provenance from `datasets/merged/manifest.json`.

Preflight checklist (data prep only, no approval needed):

```bash
cd tools/train
uv sync
uv run hold-build --force && uv run hold-bake && uv run hold-bake --verify
uv run python -m unittest discover -s tests -v
cd ../eval && npm test && npm run typecheck && npm run eval:stub
```

The preflight run itself, awaiting explicit user approval:

```bash
cd tools/train
mkdir -p artifacts
uv run hold-train-d1 --config configs/rf_detr_d1_preflight.yaml 2>&1 | tee artifacts/train_rf_detr_d1_preflight.log
```

After the approved preflight, check the log for the config echo (`device: mps`,
`seed: 20261019`), the `merged/valid` symlink line, and the checkpoint names,
then validate the export kwargs:

```bash
cd tools/train
uv run hold-export \
  --checkpoint artifacts/train_rf_detr_d1_preflight/checkpoint_best_ema.pth \
  --output artifacts/holds_detector_d1_preflight.onnx \
  --manifest artifacts/manifest_d1_preflight.json \
  --dataset-dir datasets/merged \
  --id holds_detector_d1_preflight \
  --version 0.1.0 \
  --purpose "D1 1-epoch preflight export: plumbing validation only, never shippable"
rm artifacts/train_rf_detr_d1_preflight/last.ckpt   # reclaim about 500 MB once the export succeeded
```

## D1 baseline run: RF-DETR-Nano

The run is fully specified by configs/rf_detr_d1.yaml (40 epochs, batch 4,
640 resolution, lr 1e-4, seed 20261019, device mps, output
artifacts/train_rf_detr_d1). hold-train-d1 reads the config (and validates
dataset_dir, output_dir, model, train, device, seed), creates
`datasets/merged/valid` as a symlink to `val` (RF-DETR's Roboflow-style loader
expects the name "valid"), forwards device and seed, then calls
RFDETRNano.train().

> **REQUIRES USER APPROVAL BEFORE RUNNING.** Do not run the command below until
> the user has approved the D1 training run (the preflight first, then this).

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
  --dataset-dir datasets/merged \
  --id holds_detector_d1 \
  --version 0.1.0 \
  --purpose "D1 baseline: RF-DETR-Nano on the merged hold dataset"

cd ../eval
npm install
npm run verify -- ../train/artifacts/holds_detector_d1.onnx
```

`--id`, `--version`, and `--purpose` are recorded in the export manifest;
dataset provenance points at `datasets/merged/manifest.json` (built by
`hold-build`, updated by `hold-bake`), including its SHA256.

## D1 runbook

The full flow, approval gated at every training step. Data prep and harness
tests are safe to run; every `hold-train-*` command needs explicit user
approval first.

```text
Step 0  data prep (no approval)
        cd tools/train
        uv run hold-build --force && uv run hold-bake && uv run hold-bake --verify
        uv run python -m unittest discover -s tests -v
        cd ../eval && npm test && npm run typecheck && npm run eval:stub

Step 1  preflight (REQUIRES USER APPROVAL BEFORE RUNNING)
        uv run hold-train-d1 --config configs/rf_detr_d1_preflight.yaml
        check: config keys validate, device mps + seed echoed, merged/valid
        symlink created, checkpoint_best_ema.pth present, hold-export kwargs
        produce the expected manifest

Step 2  full run (REQUIRES USER APPROVAL BEFORE RUNNING)
        uv run hold-train-d1 --config configs/rf_detr_d1.yaml 2>&1 | tee artifacts/train_rf_detr_d1.log
        40 epochs, batch 4: expect 15 to 22 hours on MPS (about 17 h at the
        measured 26 min per epoch) and about 3 GB of disk
        watch: first two epochs on screen. MPS fallback warnings (ops falling
        back to CPU, or "MPS backend out of memory") and swap pressure mean
        stop, free RAM (8 GB headroom), or set device: cpu in the config (3 to
        5 times slower) instead of letting the run silently crawl

Step 3  select the operating threshold on VAL only
        npm run eval -- --split-dir ../train/datasets/merged/val \
          --report reports/d1_val_eval.json --confidence 0.5
        pick the confidence on val; never on test

Step 4  ONE gated test run
        npm run eval -- --split-dir ../train/datasets/merged/test \
          --report reports/d1_test_eval.json --confidence <chosen> --gate \
          --i-accept-one-test-run
        the flag is mandatory (without it the harness refuses with exit 2) and
        each accepted run appends one line to reports/test_ledger.jsonl
        (timestamp, model id, report path, git describe); --gate exits 3 below
        the floors (precision >= 0.85, recall >= 0.80, mAP50 >= 0.75)
        if a gate fails: fix, retrain (approval again), tune on val, then one
        new test run and one new ledger line

Step 5  keep-best pruning
        keep checkpoint_best_ema.pth (and last.ckpt only until the export
        succeeds), delete the rest immediately: about 3 GB per run
```

## Eval gates (Phase 4 quality, docs/requirements.md section 6)

Gate thresholds: precision >= 0.85 and recall >= 0.80 at IoU 0.5, mAP@0.5 >=
0.75, measured on the frozen test split at an operating confidence chosen on
the val split (never tuned on test).

One gated test run policy: the harness defaults to the val split, and scoring
the test split requires the explicit `--i-accept-one-test-run` flag. Each
accepted test run appends one JSON line to `tools/eval/reports/test_ledger.jsonl`
(timestamp, model id, report path, git describe) so every opening of the
frozen split is on the record.

```bash
cd tools/eval

# 1. Choose the operating threshold on the val split (the default split; no flag needed).
npm run eval -- --model ../train/artifacts/holds_detector_d1.onnx \
  --split-dir ../train/datasets/merged/val \
  --report reports/d1_val_eval.json --confidence 0.5

# 2. The ONE gated test run: frozen split, chosen threshold, Phase 4 gates.
#    Without --i-accept-one-test-run the harness refuses (exit 2) before loading
#    the model. --gate exits 3 when any of precision/recall/mAP50 misses its floor.
npm run eval -- --model ../train/artifacts/holds_detector_d1.onnx \
  --split-dir ../train/datasets/merged/test \
  --report reports/d1_test_eval.json --confidence <chosen> --gate \
  --i-accept-one-test-run
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

## D1 comparison run: YOLOX-Nano (approved 2026-10-20, staged)

Apache-2.0 Megvii YOLOX only, exp file configs/yolox_d1.py (40 epochs, batch 4,
fixed 640 px with multiscale off, num_classes 1, same seed, single-process
loading; the low-memory recipe mirrors rf_detr_d1_lowmem, and YOLOX scales the
LR by batch through basic_lr_per_img, so per-image LR is unchanged). The yolox
package is deliberately not a project dependency; it lives in the isolated
environment tools/train/.venv-yolox (Python 3.12.13, torch 2.14.1, created
2026-10-20). Megvii YOLOX targets CUDA, so the installed package carries a
committed MPS device patch (tools/train/patches/yolox-0.3.0-mps.patch, 7 files,
every change CUDA-equivalent). Rebuild the environment from scratch with:

```bash
cd tools/train
uv venv .venv-yolox --python 3.12
uv pip install --python .venv-yolox/bin/python \
  torch==2.14.1 torchvision==0.29.1 pycocotools tabulate thop pillow numpy \
  setuptools wheel
# yolox 0.3.0 pins onnxruntime==1.8.0 (no Python 3.12 wheels); that dependency
# is export-only and unused for training, so --no-deps drops it, and its
# setup.py imports torch at build time, so --no-build-isolation is required.
uv pip install --python .venv-yolox/bin/python --no-deps --no-build-isolation yolox==0.3.0
uv pip install --python .venv-yolox/bin/python \
  loguru opencv-python-headless tqdm tensorboard
patch -p1 -d .venv-yolox/lib/python3.12/site-packages < patches/yolox-0.3.0-mps.patch
```

Pretrained initialization: tools/train/artifacts/pretrained/yolox_nano.pth
(7,694,953 bytes), the official Apache-2.0 Nano checkpoint from the Megvii
releases page, recorded in LICENSES.md:
https://github.com/Megvii-BaseDetection/YOLOX/releases/download/0.1.1rc0/yolox_nano.pth

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

Sanity check the MPS patch, then launch (one training job at a time, machine
otherwise idle, per the low-memory rules):

```bash
cd tools/train
.venv-yolox/bin/python configs/yolox_mps_microcheck.py
.venv-yolox/bin/python -m yolox.tools.train \
  -f configs/yolox_d1.py -b 4 -c artifacts/pretrained/yolox_nano.pth
```

Checkpoints, train_log.txt, and tensorboard events land in
artifacts/train_yolox_d1/yolox_d1/. latest_ckpt.pth is rewritten every epoch;
restart an interrupted run with --resume and WITHOUT -c:

```bash
cd tools/train
TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD=1 .venv-yolox/bin/python -m yolox.tools.train \
  -f configs/yolox_d1.py -b 4 --resume
```

Two traps to avoid:

- Do not combine --resume with -c. resume_train prefers args.ckpt when both
  are set, so it would load the pretrained nano as full training state, see
  start_epoch 291, and exit immediately without training.
- TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD=1 is required on torch 2.14 because
  latest_ckpt.pth stores the best_ap metric as a numpy scalar, which the
  weights_only loader rejects. The file is a trusted local artifact, so
  disabling the weights-only check is safe here.

Comparison protocol: export both models to ONNX, evaluate both on the same
frozen test split with the same harness, and record precision, recall, mAP@0.5,
latency, and export size in docs/research.md before picking the Phase 4 model.

## Preprocess parity with the app

Inference preprocess (letterbox 640 pad 114 centered, RGB float32 NCHW,
ImageNet normalization) lives once in tools/eval/src/preprocess.ts as pure
typed-array code, per docs/architecture.md. On the merged dataset the letterbox
is already baked in by hold-bake, so the harness letterbox over that data is an
exact identity (scale 1, zero pads, no resampling): ground truth boxes,
detections, and app preprocessing all share the 640 frame. For raw-resolution
splits (harness fixtures, own-gym photos from hold-split) the harness maps
ground truth into the letterboxed frame with the same geometry instead, and
detections come back through letterboxToSourceBox. The Phase 4 app path
(src/features/ml/preprocess.ts) must reuse the same contract so eval numbers
transfer to on-device behavior.

Parity is pinned by tests on both sides of the boundary:

```bash
cd tools/train && uv run python -m unittest discover -s tests -v  # bake geometry, boxes, round trip
cd tools/eval && npm test   # includes baked_parity.test.ts (identity on baked images)
```

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
