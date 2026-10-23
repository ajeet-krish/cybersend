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
  --checkpoint artifacts/train_rf_detr_d1/checkpoint_best_total.pth \
  --output artifacts/holds_detector_d1.onnx \
  --manifest artifacts/manifest.json \
  --dataset-dir datasets/merged \
  --id holds_detector_d1 \
  --version 1.0.0 \
  --purpose "D1 baseline: RF-DETR-Nano on the merged hold dataset"

cd ../eval
npm install
npm run verify -- ../train/artifacts/holds_detector_d1.onnx
```

`checkpoint_best_total.pth` is what was exported, and its state dict is
identical to `checkpoint_best_ema.pth`: same 466 tensors, same content hash
(`c0cc4377b9061ae9`), and `best_total_source` is `ema` at epoch 39. Either file
exports the same graph, and the total checkpoint is the canonical one because
it names its source.

`--id`, `--version`, and `--purpose` are recorded in the export manifest;
dataset provenance points at `datasets/merged/manifest.json` (built by
`hold-build`, updated by `hold-bake`), including its SHA256. Pass an absolute
path or a path relative to the repo root for `--dataset-dir`; the manifest step
resolves the path before making it repo relative (a relative path used to crash
before that fix).

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
positives per image <= 0.5) are reported in the same JSON. Sweep val before
choosing an operating point: on D1 no single threshold meets recall >= 0.80,
false positives <= 0.5, and count error <= 1.0 together (docs/research.md), and
the test split is never used for threshold selection. A threshold that satisfies
only the recall floor hides a false positive budget miss, which is what the
single test run at 0.5 showed.

 Proxy-domain gates
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

Comparison protocol and outcome: export both models to ONNX, score both on val
with the same harness, then spend the single frozen test run on whichever model
clears the accuracy thresholds. That happened on 2026-10-21. RF-DETR-Nano
cleared precision 0.9509, recall 0.8788, and mAP@0.5 0.9130 on the test split
(582 images, 24,141 holds, confidence 0.5). YOLOX-Nano fails the recall floor at
every threshold on val (0.80 recall needs confidence 0.2, where precision is
0.7168), so it was not spent on.

The full Phase 4 criteria are stricter than those three numbers. RF-DETR also
fails the false positive budget (1.88 per image versus 0.5) and cannot meet the
15 MB int8 size budget (28.9M parameters), while YOLOX meets size but not
recall. No D1 model is shippable as specified; see the gate table in
docs/research.md and the decision record in docs/decisions.md.

## D1b scaling run: YOLOX-S (completed 2026-10-22)

D1 left Phase 4 accuracy-decided but shipment-blocked, and the two D1 models
fail on opposite sides: RF-DETR-Nano meets the accuracy thresholds but misses
the false positive budget at the recall floor and cannot meet the 15 MB int8
budget at 28.9M parameters (Core ML compression does not help, see
docs/research.md). YOLOX-Nano fits size by an order of magnitude but tops out at
precision 0.7168 when recall reaches 0.80. The user chose scaling YOLOX over
revising budgets (docs/decisions.md).

Recipe: configs/yolox_s_d1.py, identical to configs/yolox_d1.py except the model
scale (depth 0.33, width 0.50, dense convolutions, 8.94M parameters at one
class). Everything else matches for comparability: fixed 640, batch 4, 40
epochs, 5 warmup, 5 no-aug, no multiscale, single-process loading, same seed.
Dense convolutions are required by the official checkpoint, which is a dense
COCO model: 456 of 462 tensors match by name and shape, 99.7% of parameters,
with only the 80-class head keys skipped (the D1 Nano build needed
`depthwise=True` for the same reason, see configs/yolox_d1.py).

Size: about 8.9M parameters, so roughly 9 MB at int8 against the 15 MB budget,
and the graph stays Conv, Sigmoid, and elementwise only. No preprocessing or
postprocessing change: the harness contract for YOLOX already covers raw 0..255
input, cxcywh pixels, and NMS at IoU 0.65.

Pretrained initialization, Apache-2.0, stored git ignored:
`artifacts/pretrained/yolox_s.pth` (72,089,125 bytes), from
https://github.com/Megvii-BaseDetection/YOLOX/releases/download/0.1.1rc0/yolox_s.pth
(recorded in LICENSES.md).

```bash
cd tools/train
.venv-yolox/bin/python -m yolox.tools.train \
  -f configs/yolox_s_d1.py -b 4 -c artifacts/pretrained/yolox_s.pth
```

Artifacts land in artifacts/train_yolox_s_d1/yolox_s_d1/ (checkpoints,
train_log.txt, tensorboard), separate from the Nano run.

Wall time in practice: about 7 min per mosaic epoch (iter_time 1.1 to 1.6 s at
epoch 10, data_time 0.12 s), and about 1.5 min per epoch once mosaic stops in the
final five. The run took roughly 4.5 h of actual compute between 21:17 and 11:15
with a long machine sleep in the middle, so do not read the clock times as pure
training time. The isolated 0.34 s/iter measurement was 3.5x optimistic, the same
factor the Nano run showed, which is worth remembering for the next estimate.

Result (details and the full comparison in docs/research.md):

| Item | Value |
|---|---|
| Best checkpoint | epoch 40, val COCO AP50 0.8377, AP50:95 0.6010 (Nano: 0.7807 / 0.5224) |
| ONNX | artifacts/holds_detector_yolox_s_d1.onnx, 36,701,782 bytes, output [1, 8400, 6] |
| Parity | PASS, 8.92e-6 score, 1.43e-6 box |
| Val at confidence 0.5 | precision 0.9380, recall 0.7656, mAP@0.5 0.8709, FP 1.9475 per image |
| Best accuracy point | confidence 0.40: 0.9029 / 0.8050 / 0.8709, FP 3.3350, count error 2 |

The accuracy thresholds now pass at one operating point, which no D1 model
achieved, and about 9 MB at int8 fits the size budget. False positives do not
pass: 3.3350 per image against 0.5 at the recall floor, 6.7x over, and count
error is 2 against a limit of 1. At confidence 0.70 false positives pass (0.4501)
but recall falls to 0.5991. So the acceptance region is still empty, and further
capacity is not the answer. See docs/decisions.md for the open options.

Evaluation after the run follows the same protocol as D1: export to ONNX, parity
check, then the val operating-curve sweep at several confidences. The frozen
test split stays unopened; a second spend needs a policy decision, not a run.

Resume traps are unchanged from the Nano section: never combine `--resume` with
`-c`, and set `TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD=1`.

## ONNX export and torch parity (D1, 2026-10-21)

Both D1 models export to ONNX opset 17 and run in `onnxruntime-node`. Numbers
below are from the completed exports, recorded in docs/research.md.

| Model | File | Bytes | Input | Outputs |
|---|---|---|---|---|
| RF-DETR-Nano | artifacts/holds_detector_d1.onnx | 109,222,362 | `input` [1,3,640,640] | `dets` [1,300,4], `labels` [1,300,2] |
| YOLOX-Nano | artifacts/holds_detector_yolox_d1.onnx | 4,587,150 | `images` [1,3,640,640] | `output` [1,8400,6] |

RF-DETR exports through the packaged path, YOLOX through the committed script
(the Megvii export script calls `torch.onnx._export`, removed in torch 2.14):

```bash
cd tools/train
# RF-DETR (also see the export block above)
uv run hold-export --checkpoint artifacts/train_rf_detr_d1/checkpoint_best_total.pth \
  --output artifacts/holds_detector_d1.onnx --manifest artifacts/manifest.json \
  --dataset-dir datasets/merged --id holds_detector_d1 --version 1.0.0

# YOLOX, run from tools/train
PYTHONPATH=src .venv-yolox/bin/python -m hold_train.export_yolox_onnx
```

`export_yolox_onnx.py` uses the legacy tracer (`dynamo=False`), keeps decode in
the graph, simplifies with onnxsim, and writes artifacts/manifest_yolox_d1.json.
It needs `onnx`, `onnxruntime`, and `onnxsim` in the YOLOX environment:

```bash
uv pip install --python .venv-yolox/bin/python onnx onnxruntime onnxsim
```

### Parity gate

`parity_check.py` runs the torch model and the ONNX graph on the same K val
images (val only, never the frozen test split) and gates on the decision space
the harness consumes, not on raw max-abs across all queries:

```bash
cd tools/train
PYTHONPATH=src .venv/bin/python -m hold_train.parity_check --model rfdetr \
  --checkpoint artifacts/train_rf_detr_d1/checkpoint_best_total.pth \
  --onnx artifacts/holds_detector_d1.onnx

PYTHONPATH=src .venv-yolox/bin/python -m hold_train.parity_check --model yolox \
  --checkpoint artifacts/train_yolox_d1/yolox_d1/best_ckpt.pth \
  --onnx artifacts/holds_detector_yolox_d1.onnx --exp-file configs/yolox_d1.py
```

The gate is max hold-score difference and max box difference over active
queries (score above `--score-threshold`, default 0.5), both against
`--tolerance` (default 1e-3). Boxes are converted to the normalized 0..1 frame
before comparison (RF-DETR emits normalized already, YOLOX emits pixels of the
640 frame), so one absolute tolerance means the same thing for both models.
Raw max-abs stays in the report as a diagnostic only: near-zero background
queries in RF-DETR are numerically ill-conditioned and swing by 0.16 on `dets`
without affecting a single detection.

Measured (5 val images each):

- RF-DETR: max hold-score diff 8.31e-4, max active-query box diff 7.15e-7. PASS.
- YOLOX: max score diff 1.06e-5, max active box diff 2.19e-6 normalized. PASS.

Reports land in artifacts/parity_rfdetr_d1.json and
artifacts/parity_yolox_d1.json (git ignored; summary in docs/research.md).

### Preprocess and postprocess contract difference

| | RF-DETR | YOLOX |
|---|---------|-------|
| Channel order | RGB | RGB |
| Scale | /255 then ImageNet mean/std | raw 0..255, no normalization |
| Letterbox pad | 114 gray, centered | 114 gray, centered |
| Box decode | in graph, normalized cxcywh | in graph, cxcywh pixels |
| NMS | none needed (set prediction) | outside the graph, IoU 0.65 over anchors >= 0.01 |

`tools/eval/src/preprocess.ts` now takes a per-model mode ("imagenet" for
RF-DETR, "raw" for YOLOX), and the detector declares which mode the core must
use, so a mismatch cannot be silently applied. YOLOX decode and NMS live in
`tools/eval/src/decode_yolox.ts`: cxcywh pixels to clipped xyxy, score =
objectness times best class, then class-agnostic greedy NMS at IoU 0.65 over
anchors scoring at least 0.01 (the COCO convention the training-side eval used).
`--model-kind` defaults to auto and reads the output names (`dets` plus
`labels` is RF-DETR, a single `output` is YOLOX); it refuses to guess otherwise.

Both exports now run end to end through `eval_hold.ts`. The cxcywh reading of
the YOLOX output was verified on a val image before the harness trusted it:
mean best IoU against ground truth is 0.79 as cxcywh and 0.00 as xyxy.

Val results at confidence 0.5 (591 images, harness, no test split involved):

| Model | precision | recall | mAP@0.5 |
|---|---|---|---|
| RF-DETR-Nano | 0.9490 | 0.8894 | 0.9235 |
| YOLOX-Nano | 0.9185 | 0.6725 | 0.8101 |

RF-DETR clears the three accuracy thresholds on val (0.85 / 0.80 / 0.75), while
YOLOX cannot clear the recall floor at any single threshold: recall reaches 0.80
only at confidence 0.2, where precision is 0.7168, and at 0.4 the pair is
0.8671 / 0.7294. The accuracy comparison therefore settles without spending the
test run on YOLOX. The deployment criteria (false positive rate, int8 size) are
not met by either model and are recorded in docs/research.md.

The harness-versus-in-loop mAP gap also shrank to noise at D1: RF-DETR scores
0.9235 here versus 0.9204 in-loop (0.0031 apart), and YOLOX 0.8101 versus 0.781
COCO mAP50 (a VOC versus COCO interpolation difference, plus NMS details).
The open reconciliation item in the eval README is effectively closed for D1.

## Core ML export and parity (D1, 2026-10-21)

Feasibility path, not a shipment path. rfdetr 1.11.2 ships a Core ML exporter
that rewrites deformable attention into a rank 5 path, so the two GridSample
nodes that were the historical Apple backend blocker do not block conversion.
The exporter pins minimum deployment target to iOS16 (the app floor) and expects
the same ImageNet normalization and 1x3x640x640 input as ONNX.

```bash
cd tools/train

# Conversion (float32 package, optional uniform weight compression).
PYTHONPATH=src .venv/bin/python -m hold_train.export_coreml \
  --checkpoint artifacts/train_rf_detr_d1/checkpoint_best_total.pth \
  --output-dir artifacts/coreml_rfdetr_d1 --precision float32 --palettize-bits 8 4

# Parity against the canonical ONNX graph (val only, never the test split).
PYTHONPATH=src .venv/bin/python -m hold_train.parity_coreml \
  --mlpackage artifacts/coreml_rfdetr_d1/rfdetr-nano_fp32.mlpackage \
  --onnx artifacts/holds_detector_d1.onnx --count 5 --compute-units CPU_ONLY
```

`parity_coreml.py` reuses the torch parity decision space (hold scores and boxes
of queries above 0.5, tolerance 1e-3) and maps the package outputs by shape
(`concat_2` dets, `linear_102` labels) rather than by position. It adds a
`--compute-units` switch: CPU_ONLY for a deterministic numeric check, ALL to
exercise the ANE path.

Measured on this machine (M5, five val images; details in docs/research.md):

| Package | Size | Parity | Notes |
|---|---|---|---|
| float32 | 104.4 MB | PASS 8.31e-4 score, 8.79e-7 box | ANE path also passes; 43.6 ms median warm, 4.16 s first call |
| float16 | 51.6 MB | FAIL 2.96e-1 score | detection count preserved on the sensitive image, one active box moves 0.59 |
| int8, 8 bit palettized | 26 MB | FAIL 4.54e-1 score | 2 of 56 detections lost on the sensitive image |
| int4, 4 bit palettized | 13 MB | FAIL 9.77e-1 score | non-finite boxes, all 56 detections lost |

Compressed packages are measurement artifacts only. The only parity-clean
package is 104.4 MB, so Core ML does not resolve the 15 MB budget. Compression
modes in coremltools are KMEANS (needs scikit-learn), UNIFORM, UNIQUE, CUSTOM;
the recorded variants used UNIFORM on a float16 package.

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

### Harness mAP vs RF-DETR in-loop validation mAP (closed at D1)

Recorded in tools/eval/reports/smoke_eval.json: RF-DETR's in-loop validation
mAP@50 logged during the Phase 0 smoke run was higher than what the Node
harness computes on the same split with standard single-class AP@0.5 semantics.
Harness correctness was verified directly on that run (preprocess parity with
RF-DETR's Normalize transform, ONNX boxes within a few pixels of torch
predict).

D1 status: the gap does not reproduce. On the D1 val split the harness gives
mAP@0.5 0.9235 against 0.9204 in-loop (0.0031 apart), and YOLOX gives 0.8101
against 0.781 COCO mAP50, consistent with VOC all-point versus COCO 101-point
interpolation. D1 gate numbers are treated as authoritative; the smoke record
stays as history and gates nothing.

## History note

The Phase 0 smoke spike (ClimbInst subset, CC BY-NC-SA 4.0, smoke checkpoint,
smoke ONNX) was retired on 2026-10-19: its dataset and artifacts were deleted
when the merged D1 dataset landed. tools/eval/reports/smoke_eval.json remains
only as a historical record of that spike and references artifacts that no
longer exist; it gates nothing. The memory-pressure lessons from that spike
(RAM headroom, swap exhaustion kills) still apply to D1 runs.
