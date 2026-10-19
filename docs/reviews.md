# CyberSend Reviews

Last updated: 2026-10-19 (post ML-D0 architecture review)

Architecture and code review log. One entry per review, newest first.

## Entry Template

### [Date], Phase [N]: [Scope reviewed]

- Reviewer:
- Result: pass, pass with follow-ups, or fail
- Findings:
- Follow-ups (owner and phase):

## Open Follow-ups

- Reconcile harness mAP against RF-DETR in-loop validation mAP before D1 gate numbers are authoritative (tools/train/README.md Troubleshooting).
- Decide letterbox baking for datasets/merged before the D1 run; preprocess parity for raw images is unverified (tools/eval/src/preprocess.ts).
- Fix hold-train-d1 to forward device and seed from configs/rf_detr_d1.yaml (currently silently dropped).
- Remap merged COCO category id 0 to 1, or verify rfdetr 1.11.2 tolerates id 0 (smoke path proved id 1 only).
- Change the D1 model comparison protocol to select on val and score the frozen test once (tools/train/README.md comparison protocol).
- Reconcile requirements vs docs/schema.sql domain drift (grade storage, hold role, fell_on_hold_id naming) before Phase 1 migrations.
- Reconcile source export dates across build_dataset.py, DATASET_CARD.md, LICENSES.md.

### 2026-10-19, Phase 0 and 1: repo-wide review plus ML training architecture (post ML-D0, HEAD 252d677)

- Reviewer: tech-lead agent (architecture review, no training executed)
- Result: pass with follow-ups overall. Per area: A training architecture PASS WITH FINDINGS, B eval harness FAIL (one blocking contract question on the D1 data path), C repo-wide PASS WITH FINDINGS, D risk list recorded.
- Findings (severity, area):
  - CRITICAL (B): preprocess parity is proven only for letterbox-baked images (the retired smoke path). datasets/merged is raw resolution, so RF-DETR trains on its own Resize((640,640)) transform while the harness letterboxes. Either bake letterbox into the merged splits before D1 training or match RF-DETR's native transform in tools/eval/src/preprocess.ts. This decision must precede the training run.
  - MAJOR (A): merged COCO writes category id 0 (build_dataset.py) while the smoke-proven hold-convert path writes id 1; rfdetr loaders may assume 1-based ids. Remap or verify before D1.
  - MAJOR (A): configs/rf_detr_d1.yaml device and seed keys are silently dropped by train_d1.py, breaking the run's reproducibility claim. train_smoke.py proves model.train() accepts both kwargs.
  - MAJOR (A): the D1 comparison protocol scores both architectures on the frozen test and then picks one, which is model selection on test. Select on val; score test once for the chosen model. Freeze discipline is procedural only; eval_hold.ts even defaults --split-dir to test.
  - MAJOR (A): the "no cluster spans two splits" sanity check is tautological (same union-find as construction) and does not guard the real risk, dedupe under-merge. Residual duplicate pairs land in different splits with probability about 0.56. Run a cross-split near-duplicate audit at a wider pHash radius before trusting metrics.
  - MAJOR (B): open metric-semantics gap between RF-DETR in-loop validation mAP and the harness AP (recorded in smoke_eval.json, previously referenced nowhere). Now documented in tools/train/README.md Troubleshooting; reconcile before gating.
  - MAJOR (B/C): export_onnx.py writes smoke identity fields ("id": "holds_detector_smoke", "purpose": "not a shippable model") into any manifest, including manifest_d1.json, and its dataset block looks for files datasets/merged does not have (split_manifest.json, LICENSE, NOTICE.json). Weakens US-34 provenance. Parameterize before the D1 export.
  - MAJOR (C): requirements vs schema.sql drift on grade storage (scheme_id/level_id vs grade_system/grade_raw), hold role fields, fell_on_hold_id naming, gym archive semantics. Resolve before Phase 1 migrations.
  - MINOR (A, B, C): determinism digests vary across days (date_created embedded in digested JSON); source export dates disagree across three records; decode assumes sigmoid channel 0 and dims-based tensor selection; center errors are letterbox-frame pixels; secondary Phase 4 numerics are reported but not gated; export() and extra train() kwargs need a one-epoch preflight; .gitignore lacks .env; LICENSES.md understates the transitive toolchain set; hold-download can still fetch the retired never-shippable ClimbInst fallback.
  - PASS notes: two-stage dedupe design is sound and honestly documented (correlation verification correctly rejects pHash over-merge on wall imagery); cluster split is deterministic and near-target ratio; manifest counts match the dataset card exactly; gate thresholds match requirements section 6 and the harness AP is unit-tested against known VOC 2010+ examples; real-model decode and preprocess parity were proven in the smoke run; dependency budgets are lean and license-clean for a store build; board seam, flags, and Kilter-cut state are consistent everywhere after this review's doc fixes.
- Follow-ups (owner and phase): the pre-D1 checklist in the review output (tech lead and backend-dev, Phase 4 prep); requirements vs schema reconciliation (PM and Phase 1); eval leakage controls in tooling (Phase 4).

Docs updated in this review: AGENTS.md (quick commands verified and tools commands added), docs/architecture.md (eval harness and folder map), docs/tests.md (ML gates to requirements numbers), docs/decisions.md (phase renumber and YOLOv8n supersession annotations, attribution list), docs/requirements.md (dataset attributions), docs/research.md (attribution row), tools/train/README.md (pwals license verified, Troubleshooting section), tools/train/DATASET_CARD.md (stale license line, sanity check wording), tools/train/LICENSES.md (attribution list), tools/train/src/hold_train/build_dataset.py (pwals license note only).
