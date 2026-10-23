# CyberSend Research Log

Last updated: 2026-10-21 (D1 ONNX export and torch parity)

Findings and open questions from spikes and literature checks. Spike checklist for Phase 0; fill results as spikes complete.

## Phase 0 Spike Checklist

| Spike | Question | Status | Notes |
|-------|----------|--------|-------|
| License: Roboflow hold model | Can we ship trained weights in a store build? | Open | Fallback: train on self-collected or permissive data; record license id in assets/models/manifest.json |
| License: hold detection model | Apache-2.0 path (YOLOX-Nano or RF-DETR-Nano) confirmed, dataset attributions recorded (climbtag, blackcreed, pwals all CC BY 4.0, own photos) | Open | Gate for Phase 4; Ultralytics AGPL excluded by user decision 2026-10-19; Kilter cut from roadmap so no board license spike remains (re-entry only with written permission) |
| Inference perf: self-trained detector (ONNX via onnxruntime-react-native, fast-tflite Core ML fallback) | Latency and memory on iPhone 11/12 class, CoreML vs CPU, ORT RN 1.24.3 Expo integration viability (time boxed, known issues) | Open | Budget: p50 <= 500 ms, p95 <= 1500 ms per photo; INT8 quantization if over budget |
| Inference perf: MoveNet frame processors | Sustained Hz on vision-camera frames | Open | Budget: 8 to 12 Hz sustained without dropped recorder frames |
| MediaPipe Tasks RN binding | Is a maintained binding viable? | Open | Alternative: react-native-fast-tflite (default bet) |
| ML eval set | Collect 20 labeled gym photos and 5 labeled clips | Open | Labels normalized 0..1 per docs/tests.md |
| op-sqlite on iOS dev client | Build, WAL, transactions smoke | Open | Blocks Phase 1 scaffold |
| Skia photo memory | 2048 px downscale policy on older devices | Open | Affects tagging canvas design |

## Conventions

- Record decision-relevant facts here, decisions themselves go to docs/decisions.md.
- Each spike ends with a short note and, if it changes design, a new decision entry.

## 2026-10-19 - Climbing Hold Dataset Source Review

Scope: four user-provided sources. Goal is single-class hold detection for photo tagging prefill, Apache-2.0 clean model, evaluated on 200+ own gym photos.

| Source | Images | Format | Classes | License | Verdict |
|--------|--------|--------|---------|---------|---------|
| Roboflow climbtag/climbing-hold-detection-7uehq | 1,873 source, 29 versions, v29 4,931 augmented | Instance segmentation polygons | hold, volume | CC BY 4.0 | USE AS BASE |
| Roboflow blackcreed-xpgxh/climbing-holds-and-volumes | 1,717 source, 8 versions, v14 4,301 augmented | Bounding boxes | "0", "1" (hold/volume per description) | CC BY 4.0 | USE AS SUPPLEMENT |
| Kaggle tomasslama/indoor-climbing-gym-hold-segmentation | 2,273 images, 19 hand-labeled, 12.1 GB | VGG VIA polygons | hold, volume | CC BY-SA 4.0 (code GPL-3.0) | SKIP |
| reiffd7/BoulderVision | 0 | Inference-only Python demo | n/a | No license (all rights reserved) | CONCEPT ONLY |

Key facts:

- climbtag: 1,873 images, 2 classes, CC BY 4.0, vendor-reported model precision 93.1, recall 86.1, mAP50 91.3 on its own split. Previews show varied real gym photos including phone shots and close-ups. Latest v29 is 4,931 images with 3x augmentation; v25 is 1,903 images and looks like the unaugmented snapshot. Export COCO JSON and use the bbox field, or derive axis-aligned boxes from polygons. Merge volume into hold for single-class tagging.
- Blackcreed: 1,717 images, object detection boxes, CC BY 4.0, 296 downloads, last updated 2023. Classes are sanitized to "0" and "1", so class semantics must be confirmed visually. v14 has 3x augmentation including 90 degree rotations and hue +/-180, which creates unrealistic colors. Prefer v12 (1,650) if an unaugmented export is needed. Merge both classes to hold.
- Kaggle: 12.1 GB, 2,273 images total. Only 19 images are hand-labeled (15 bh, 2 bh-phone, 2 sm) with 1,688 polygons. The full bh annotation has 51,116 labels, of which 49,629 are pre-labeled, not human ground truth. This is a segmentation and route research dataset, not a detection training set. CC BY-SA 4.0 and GPL-3.0 code add copyleft risk for an Apache-2.0 shipping path.
- BoulderVision: personal project and Roboflow blog demo by Daniel Reiff, not a paper and not a dataset. It calls a hosted Roboflow workflow (`detect-holds-v17`) for hold detection plus pose keypoints, with custom Python blocks for trajectory similarity, velocity ratio, and cumulative distance. No weights, no dataset, no training or eval code, no LICENSE file. Reuse the metric definitions and ByteTrack/smoothing pattern, but reimplement rather than copy unlicensed code. The name in our Phase 5 plan comes from this project; avoid implying affiliation.

Download mechanics:

- Roboflow: free account, then Dataset tab, select version, Download Dataset, Continue, pick format (COCO JSON recommended), download ZIP or copy API snippet. Scripted downloads need an API key from Settings > API Keys. Free tier is 10 credits per month (~30 model trainings or 80k hosted inferences), 20 projects, uncapped dataset size, 5x augmentation. Dataset download/export is not documented as credit-consuming.
- Roboflow license: no separate click-through checkbox is documented. The license is shown on the project page and in the download flow. Downloading is acceptance of the displayed license. If a modal shows a license agreement checkbox, it appears after format selection and before the final download or Continue action.
- Kaggle: account, then Settings > API > Generate New Token, save token, `pip install kaggle`, then `kaggle datasets download -d tomasslama/indoor-climbing-gym-hold-segmentation -p data --unzip`. No click-through license gate for standard datasets. CC BY-SA attribution and share-alike obligations still apply.

Practical notes:

- Deduplicate across Roboflow sources by perceptual hash before merging. Climbing datasets on Universe commonly reuse images, and duplicate images across train and val can inflate metrics.
- Split by image hash, not by augmented copy, and keep a held-out set of own gym photos only.
- Attribution text for CC BY 4.0 sources belongs in the app About screen and in assets/models/manifest.json.
- Volume handling is a product decision. Recommendation: merge volume into hold, since volumes are climbable surfaces and a second class adds no tagging value.

Citations:

1. climbtag, Climbing Hold Detection, Roboflow Universe, CC BY 4.0. https://universe.roboflow.com/climbtag/climbing-hold-detection-7uehq
2. Blackcreed, Climbing Holds and Volumes, Roboflow Universe, CC BY 4.0. https://universe.roboflow.com/blackcreed-xpgxh/climbing-holds-and-volumes
3. Tomas Slama, Indoor Climbing Gym Hold And Route Segmentation, Kaggle, CC BY-SA 4.0. https://www.kaggle.com/datasets/tomasslama/indoor-climbing-gym-hold-segmentation
4. xiaoxiae, Indoor Climbing Hold and Route Segmentation, GitHub, GPL-3.0. https://github.com/xiaoxiae/Indoor-Climbing-Hold-and-Route-Segmentation
5. Daniel Reiff, BoulderVision, GitHub, no license. https://github.com/reiffd7/BoulderVision
6. Roboflow, Download a Universe Dataset. https://docs.roboflow.com/datasets/universe/universe/download-a-universe-dataset
7. Roboflow, Pricing, Free Tier. https://roboflow.com/pricing
8. Kaggle CLI, Datasets Commands. https://github.com/Kaggle/kaggle-cli/blob/main/docs/datasets.md

## 2026-10-19 - Apple Platform Stack Decision Research

Scope: facts for the React Native (Expo) versus native iOS (Swift, SwiftUI, Core ML) decision. Target hardware is an M5 MacBook Pro for training and iPhone 11 or newer, with iPhone 12+ as the target class.

| Topic | Finding | Confidence | Source |
|-------|---------|------------|--------|
| ORT RN and ANE | ONNX Runtime RN exposes the CoreML EP and an ANE-only flag, but ONNX Runtime documents that the flag does not guarantee the whole model runs on ANE. Unsupported ops fall back and split the graph into partitions. | High | https://onnxruntime.ai/docs/execution-providers/CoreML-ExecutionProvider.html |
| RF-DETR ONNX to CoreML | A desktop report measured 90 CoreML partitions, 737 of 913 nodes supported, and about 290 ms versus about 70 ms for PyTorch MPS on an M2 Max. Another conversion path reports 13 to 97 partitions. | Medium | https://github.com/roboflow/rf-detr/issues/172 and https://github.com/roboflow/rf-detr/issues/318 |
| RF-DETR native CoreML on iPhone | About 61 ms on iPhone 14 Pro, with profiling showing GPU only and no ANE use. | Medium | https://github.com/roboflow/rf-detr/issues/318 |
| RF-DETR CoreML pitfalls | CoreML supports rank 5 at most, so 6D deformable attention must be reshaped. Bicubic upsampling is unsupported. FP16 fails catastrophically because of grid_sample precision, so FP32 is required in the tested path. | High | https://github.com/roboflow/rf-detr/issues/318 and https://github.com/roboflow/rf-detr/issues/172 |
| RF-DETR export support | Official `export(format="coreml")` has existed since RF-DETR 1.9.0. Core AI `.aimodel` export was added later. | High | https://github.com/roboflow/rf-detr/issues/172 |
| YOLO26 CoreML ANE | YOLO26n INT8 at 640 on iPhone 17 Pro measured 3.2 ms with CPU plus ANE versus 9.2 ms CPU only, end to end. | High | https://docs.ultralytics.com/integrations/coreml |
| ORT RN version lag | `onnxruntime-react-native` latest is 1.24.3, published 2026-03-05. ONNX Runtime core is 1.31.0, about seven minor versions ahead. | High | https://registry.npmjs.org/onnxruntime-react-native and https://pypi.org/pypi/onnxruntime/json |
| ORT RN Expo issues | Open and closed-stale reports include model load failure in Expo 54 standalone iOS, and Expo autolinking excluding the module because of `unimodule.json`. | High for existence, medium for prevalence | https://github.com/microsoft/onnxruntime/issues/27062 and https://github.com/microsoft/onnxruntime/issues/29004 |
| YOLOX on ORT RN | No public iPhone benchmark of YOLOX through ORT RN plus CoreML EP was found. YOLOX is a CNN without grid_sample or attention, so partitioning risk is lower than DETR, but this must be measured. | Low, evidence thin | No direct source found |
| Vision 2D pose accuracy | Google's own benchmark reports Apple Vision mAP 32.8 Yoga, 36.4 Dance, 44.5 HIIT, versus BlazePose GHUM Heavy 68.1, 73.0, 74.0. PCK@0.2 is 82.7, 91.4, 88.6 versus 96.4, 97.2, 97.5. | High for the table, medium for currency (2021) | https://github.com/google-ai-edge/mediapipe/blob/master/docs/solutions/pose.md |
| Vision 3D pose | `VNDetectHumanBodyPose3DRequest` returns one skeleton for the most prominent person, with joints in meters relative to a root joint. A 2024 third-party benchmark lists 17 keypoints and 50 FPS on iPhone 11. | High for API, medium for performance | https://developer.apple.com/documentation/vision/identifying-3d-human-body-poses-in-images and https://www.hingehealth.com/resources/articles/truemotions-advanced-3d-pose-estimation-sets-a-new-standard-for/ |
| iOS 18 Vision | Holistic body pose detects body and both hands in one request. The new Swift API supports concurrency and Swift 6, and Apple states new Vision features will ship in Swift only. | High | https://developer.apple.com/videos/play/wwdc2024/10163/ |
| iOS 26 Vision | The WWDC26 Vision session adds tap-to-segment, Foundation Models image input, and watchOS support. No body pose or 3D pose accuracy improvement was announced. | Medium | https://developer.apple.com/videos/play/wwdc2026/237/ |
| Climbing-specific pose accuracy | No published benchmark of Vision or MediaPipe on climbing footage was found. Our MediaPipe Heavy hold-usage figure of 83.5 percent and hand occlusion figure of 50.5 percent are not directly comparable to Vision. | Low, evidence thin | No direct source found |
| Frame budget | 60 Hz is 16.7 ms per frame, 55 fps is 18.2 ms, and 120 Hz is 8.3 ms. A 100 marker canvas leaves most of that budget for layout and compositing. | High (arithmetic) | N/A |
| SwiftUI Canvas guidance | Apple states that per-view bookkeeping and storage can become too expensive at high element counts, and that Canvas exists for those cases. Canvas is a single drawing, so per-element gestures and accessibility need custom handling. | High | https://developer.apple.com/videos/play/wwdc2021/10021/ |
| Canvas versus view per shape | A small published comparison of 50 cards with 147 diamonds each found Canvas much faster than laying out one view per shape. No 100 marker drag benchmark was found. | Medium | https://swdevnotes.com/swift/2022/better-performance-with-canvas-in-swiftui/ |
| Metal | Metal is lower level and not a free performance boost; it costs substantially more code. Use only if Canvas profiling shows a bottleneck. | Medium | https://www.reddit.com/r/SwiftUI/comments/1myy0md/canvas_vs_metal_apis_for_a_canvalike_application/ |
| Skia size and performance | React Native Skia documents about 6 MB iOS app size growth. It renders on the UI thread through JSI and is the RN equivalent of a high performance canvas. | High for size, medium for performance | https://github.com/Shopify/react-native-skia/issues/1745 |
| GRDB performance | GRDB 7 fetches 200,000 rows of 10 ints in 0.14 s with column names, versus 0.04 s for raw SQLite. It inserts 50,000 rows in 0.12 s. | High | https://github.com/groue/GRDB.swift/wiki/Performance |
| GRDB migrations | `DatabaseMigrator` uses its own `grdb_migrations` table, named forward migrations, and one transaction per migration. It does not use `PRAGMA user_version`. | High | https://github.com/groue/GRDB.swift/blob/master/GRDB/Migration/DatabaseMigrator.swift |
| op-sqlite | Version 18.2.5, September 2026. JSI based, sync and async, prepared statements, WAL, reactive queries, FTS5, SQLCipher. No built-in migration runner; Drizzle integration exists. | High for features, medium for migration claim | https://github.com/OP-Engineering/op-sqlite and https://orm.drizzle.team/docs/sqlite/connect-op-sqlite |
| RN SQLite on iOS | A 2024 benchmark found similar iOS performance across op-sqlite, quick-sqlite, and expo-sqlite. Transactions and batching matter more than driver choice. 100,000 rows is small for all of them. | Medium | https://powersync.com/blog/react-native-database-performance-comparison |
| GRDB versus op-sqlite | No direct cross-stack benchmark was found. Comparing a Swift library to a JS JSI wrapper is not meaningful without measuring the same workload on device. | Low, evidence thin | No direct source found |
| MLX detection training | YOLO26-MLX reports accuracy parity within 0.5 percent, 1.1x to 2.6x faster inference, and up to 1.7x faster training than PyTorch MPS on an M4 Pro. | High for the vendor benchmark, medium for generality | https://www.webai.com/blog/running-yolo26-natively-on-apple-silicon-with-mlx |
| RF-DETR on MLX | No MLX implementation was found. An unofficial Apple Silicon fork is PyTorch based. | Medium | https://github.com/Ak-Gautam/rf-detr-mac |
| RF-DETR on MPS | A missing `aten::_upsample_bicubic2d_aa.out` MPS operator blocked RF-DETR and was reported fixed in version 1.6. MPS fallback to CPU is slow. | High | https://github.com/roboflow/rf-detr/issues/223 |
| MPS limits | Some PyTorch ops fall back to CPU on MPS and float64 is unsupported, so not every detection training path is fully GPU resident. | High | https://docs.pytorch.org/docs/stable/notes/mps.html |
| Xcode Previews | Developers still report slow and unreliable SwiftUI previews in 2025 and 2026, including Xcode 26. Xcode 26 adds faster incremental preview updates, but reliability complaints persist. | Medium | https://www.reddit.com/r/SwiftUI/comments/1oteqd3/swiftui_previews_are_still_a_mess_in_2025/ and https://stackoverflow.com/questions/79813033/swiftui-preview-not-working-in-xcode-26-when-automatically-refresh-canvas-is-e |
| Swift Testing | Swift Testing runs tests in parallel by default and has parameterized tests. One report found 1,000 Swift Testing tests compiled about 24 times slower than 1,000 XCTest tests, improving when split. | Medium | https://github.com/swiftlang/swift-testing/issues/502 |
| App size | A minimal RN iOS App Store download is just under 4 MB. Skia adds about 6 MB, before ONNX Runtime and models. A real optimized Expo app has shipped at 47 MB iOS. | Medium | https://docs.expo.dev/distribution/app-size/ and https://github.com/Shopify/react-native-skia/issues/1745 |
| Cold start | Apple targets first frame within 400 ms. Expo recommends RN cold launch under 1.5 s. RN must load and evaluate the JS bundle before first render. | High | https://expo.dev/articles/app-performance-and-reliability/measure-mobile-app-performance |

Practical implications for CyberSend:

- If native wins, use `VNCoreMLRequest` or `MLModel` with `.cpuAndNeuralEngine`, not `.all`, and measure ANE placement with an Xcode Core ML performance report.
- Treat RF-DETR as a CoreML-only model. Do not plan to ship it through ONNX Runtime RN plus CoreML EP.
- YOLOX is the lower risk CoreML export. It still needs a Phase 0 device benchmark before it becomes the plan of record.
- Vision body pose is acceptable for gross body keypoints, velocity, and fall events. Do not claim climbing-specific accuracy without an own-data benchmark.
- SwiftUI Canvas is the default for 100+ markers. Budget custom hit testing and accessibility from day one.
- GRDB brings migrations for free, but its migration table is not `PRAGMA user_version`. Pick one source of truth.
- Stay on PyTorch MPS for RF-DETR training. MLX is only credible if the model choice lands on YOLO26 and local throughput becomes the bottleneck.

Citations:

1. ONNX Runtime, CoreML Execution Provider. https://onnxruntime.ai/docs/execution-providers/CoreML-ExecutionProvider.html
2. Roboflow, RF-DETR issue 172, export to CoreML. https://github.com/roboflow/rf-detr/issues/172
3. Roboflow, RF-DETR issue 318, explicit CoreML conversion pipeline. https://github.com/roboflow/rf-detr/issues/318
4. Ultralytics, CoreML export for YOLO26. https://docs.ultralytics.com/integrations/coreml
5. Microsoft, ONNX Runtime issue 27062, Expo 54 model load failure. https://github.com/microsoft/onnxruntime/issues/27062
6. Microsoft, ONNX Runtime issue 29004, Expo autolinking exclusion. https://github.com/microsoft/onnxruntime/issues/29004
7. Google, MediaPipe Pose quality benchmark. https://github.com/google-ai-edge/mediapipe/blob/master/docs/solutions/pose.md
8. Apple, Identifying 3D human body poses in images. https://developer.apple.com/documentation/vision/identifying-3d-human-body-poses-in-images
9. Apple, Discover Swift enhancements in the Vision framework, WWDC24. https://developer.apple.com/videos/play/wwdc2024/10163/
10. Apple, What's new in image understanding, WWDC26. https://developer.apple.com/videos/play/wwdc2026/237/
11. Apple, Add rich graphics to your SwiftUI app, WWDC21. https://developer.apple.com/videos/play/wwdc2021/10021/
12. GRDB, Performance wiki. https://github.com/groue/GRDB.swift/wiki/Performance
13. GRDB, DatabaseMigrator source. https://github.com/groue/GRDB.swift/blob/master/GRDB/Migration/DatabaseMigrator.swift
14. OP Engineering, op-sqlite. https://github.com/OP-Engineering/op-sqlite
15. PowerSync, React Native database performance comparison. https://powersync.com/blog/react-native-database-performance-comparison
16. webAI, Running YOLO26 natively on Apple Silicon with MLX. https://www.webai.com/blog/running-yolo26-natively-on-apple-silicon-with-mlx
17. Roboflow, RF-DETR issue 223, MPS backend. https://github.com/roboflow/rf-detr/issues/223
18. Expo, Understanding app size. https://docs.expo.dev/distribution/app-size/
19. Expo, How to measure mobile app performance. https://expo.dev/articles/app-performance-and-reliability/measure-mobile-app-performance
20. Shopify, React Native Skia issue 1745, package size. https://github.com/Shopify/react-native-skia/issues/1745

## 2026-10-21 - D1 ONNX export and torch parity

Both D1 models now export to ONNX opset 17 and were checked against their
PyTorch sources on val data. Nothing here touches the frozen test split.

### Export artifacts

| Item | RF-DETR-Nano | YOLOX-Nano |
|------|--------------|------------|
| Source checkpoint | artifacts/train_rf_detr_d1/checkpoint_best_total.pth (`best_total_source` is ema, epoch 39; state dict identical to checkpoint_best_ema.pth, 466 tensors, hash c0cc4377b9061ae9) | artifacts/train_yolox_d1/yolox_d1/best_ckpt.pth (epoch 40, best mAP) |
| ONNX file | artifacts/holds_detector_d1.onnx | artifacts/holds_detector_yolox_d1.onnx |
| Size | 109,222,362 bytes (109.2 MB) | 4,587,150 bytes (4.59 MB) |
| Input | `input` float32 [1,3,640,640] | `images` float32 [1,3,640,640] |
| Outputs | `dets` [1,300,4] normalized cxcywh, `labels` [1,300,2] class logits | `output` [1,8400,6] x1,y1,x2,y2 in pixels, objectness, class score |
| Manifest | artifacts/manifest.json (version 1.0.0) | artifacts/manifest_yolox_d1.json |
| Postprocess location | decode in graph, NMS in the harness | decode in graph, NMS outside the graph |
| CPU latency (onnxruntime-node, 1 image) | 153 ms | 13 ms |

The RF-DETR names and shapes match the contract `tools/eval/src/decode.ts`
already consumes: `dets` are normalized cxcywh per query, and `labels` channel 0
is the hold logit (independent sigmoid, no softmax; the trailing channel is
no-object). Output order is not score sorted, and the harness thresholds and
sorts downstream. A TopK node does exist inside the transformer (two-stage
query selection), but it does not order the graph outputs. The YOLOX output is
the raw 8400 anchor decode with no clipping and no NMS; boxes routinely exceed
the frame (measured max 5512 px before clipping).

Graph size: RF-DETR 1424 nodes, YOLOX 378 nodes after simplification.

### Export tooling findings

- torch 2.14 removed `torch.onnx._export`. The Megvii YOLOX export script calls
  it and dies. The replacement export must use the legacy tracer explicitly
  (`torch.onnx.export(..., dynamo=False)`); the dynamo exporter was not used
  here, so its behavior on this model is unverified.
- `rfdetr.from_checkpoint()` returns a `ModelContext` wrapper; the nn module
  is `rf.model.model`, and its `export()` swaps every submodule forward to its
  export variant in place. Repeated calls on one instance were exercised by the
  parity tool without error.
- `export_onnx.py` crashed on a relative `--dataset-dir` because the manifest
  step called `.relative_to(PROJECT_ROOT)` on an unresolved path. Fixed with
  `resolve()`. A relative dataset path is now accepted.
- onnxsim simplifies the YOLOX graph to 378 nodes and is used so a Core ML
  conversion attempt starts from a canonical graph (dynamic shapes off); the
  RF-DETR graph is left as exported.

### Parity protocol and results

Parity is scored on the decision space the harness consumes: hold score
agreement plus box agreement over queries whose score clears 0.5. Raw max-abs
over all 300 queries is recorded but is not a gate, because near-zero
background queries have ill-conditioned box regressions.

| Model | Max score diff | Max active-query box diff (normalized) | Gate (1e-3) |
|-------|----------------|----------------------------------------|-------------|
| RF-DETR-Nano | 8.31e-4 | 7.15e-7 | PASS |
| YOLOX-Nano | 1.06e-5 | 2.19e-6 | PASS |

RF-DETR raw max-abs reached 0.1597 on `dets` and 0.4354 on `labels` on one
image. Isolation showed the cause: hold scores agree to 8.3e-4 there, the
top-20 query sets are identical (20 of 20), and only 3 of 300 queries cross
0.5 in both runs. The large deltas sit on queries with scores near 0.003, so no
detection changes. This is consistent with FP32 versus ONNX Runtime accumulation
differences on near-saturated background logits, not an export defect.

YOLOX boxes are emitted in pixels of the 640 frame, so the gate normalizes them
by 640 before comparing. Without that, the same 1.4e-3 pixel difference reads
as a failure against a 1e-3 gate that was authored for 0..1 coordinates.

### Harness support for YOLOX, and val gate numbers

| | RF-DETR | YOLOX |
|---|---------|-------|
| Channel order | RGB | RGB |
| Scale | /255 then ImageNet mean/std | raw 0..255, no normalization |
| Letterbox pad | 114 gray, centered | 114 gray, centered |
| Box decode | in graph, normalized cxcywh | in graph, cxcywh pixels |
| NMS | none needed (set prediction) | harness, IoU 0.65 over anchors >= 0.01 |

The harness gained a per-model preprocess mode, declared by the detector, plus
YOLOX decode and NMS (`tools/eval/src/decode_yolox.ts`). No silent fallback: a
model whose output names match neither contract is rejected and requires
`--model-kind`. The cxcywh reading was verified against ground truth before the
harness trusted it (mean best IoU 0.79 as cxcywh, 0.00 as xyxy).

Val results at confidence 0.5, 591 images, no test split involved:

| Model | precision | recall | mAP@0.5 | Accuracy thresholds (0.85 / 0.80 / 0.75) |
|---|---|---|---|---|
| RF-DETR-Nano | 0.9490 | 0.8894 | 0.9235 | PASS (three of three) |
| YOLOX-Nano | 0.9185 | 0.6725 | 0.8101 | FAIL (recall) |

YOLOX cannot clear the recall floor at any single threshold. Recall reaches 0.80
only at confidence 0.2, where precision is 0.7168; the pair at 0.4 is
0.8671 / 0.7294; at 0.3 it is 0.8033 / 0.7699. Precision and recall trade
monotonically, so no threshold satisfies both floors. This decides the accuracy
comparison on val alone, before any test-split spend. It does not settle the
deployment criteria, which both models miss for different reasons (see the
frozen test section).

The harness-versus-in-loop mAP gap also collapsed at D1: RF-DETR scores 0.9235
here against 0.9204 in-loop (0.0031 apart), and YOLOX 0.8101 against 0.781 COCO
mAP50, which is consistent with VOC all-point versus COCO 101-point
interpolation plus NMS details. The reconciliation item in the eval README is
closed for D1.

### Operating curve on val (2026-10-21)

The frozen test run fixed the operating threshold at 0.5, chosen on val. The full
val curve shows why no threshold was chosen higher: the acceptance region is
empty.

| confidence | precision | recall | FP per image | median count error |
|---|---|---|---|---|
| 0.50 | 0.9490 | 0.8894 | 1.8393 | 1 |
| 0.60 | 0.9616 | 0.8757 | 1.3486 | 1 |
| 0.70 | 0.9751 | 0.8472 | 0.8342 | 2 |
| 0.75 | 0.9808 | 0.8172 | 0.6176 | 3 |
| 0.80 | 0.9858 | 0.7603 | 0.4213 | 4 |

Requirements need recall >= 0.80, false positives <= 0.5 per image, and median
count error <= 1.0 at the same threshold. At 0.75 recall passes (0.8172) but FP
is 0.62 and count error is 3. At 0.80 FP passes (0.4213) but recall 0.7603 and
count error 4 fail. Count error stays at 1 only up to 0.60, where FP is 1.35.

Interpolating between 0.75 and 0.80, the lowest threshold that still holds
recall at 0.80 is about 0.765, where FP per image is about 0.56 and count error
is about 3. So the best available point misses the FP budget by roughly 12% and
the count error limit by two holds, while the earlier test figure of 1.8832 FP
per image was measured at 0.5, well below the recall floor. Read together: no
re-thresholding of D1 passes, but the gap at the recall floor is small enough to
be a model quality target rather than a rewrite.

Two consequences for how the frozen test result is read. The 0.5 run assessed
recall, precision, and mAP at a defensible operating point, and those pass. It
did not assess the FP budget at a threshold chosen to satisfy the criteria,
because none exists; the 1.8832 figure is therefore an upper bound at an
operating point the product would not use. The test run is spent either way, so
the conclusion has to rest on val.

### Frozen test result (the single gated run, 2026-10-21)

RF-DETR-Nano, 582 frozen images, 24,141 ground truth holds, operating
confidence 0.5, model `holds_detector_d1` version 1.0.0. Recorded in
`tools/eval/reports/d1_test_eval.json` and `reports/test_ledger.jsonl`; the run
consumed the one-run allowance.

Accuracy criteria, docs/requirements.md section 6:

| Criterion | Value | Limit | Result |
|---|---|---|---|
| precision@IoU0.5 | 0.9509 | >= 0.85 | PASS |
| recall@IoU0.5 | 0.8788 | >= 0.80 | PASS |
| mAP@0.5 | 0.9130 | >= 0.75 | PASS |
| median per-image hold-count error | 1.0 | <= 1.0 | PASS (boundary) |
| false positives per image | 1.8832 | <= 0.5 | FAIL, 3.8x over |

Val to test movement is small and in both directions: mAP@0.5 0.9235 to 0.9130,
precision 0.9490 to 0.9509, recall 0.8894 to 0.8788. A gap that size after
threshold selection on val means the operating point did not overfit the val
split.

Deployment criteria, same section, are not met or not yet measured:

| Criterion | Value | Limit | Result |
|---|---|---|---|
| int8 model size bundled | 109.2 MB float32; about 29 MB as int8 (28.9M parameters) | <= 15 MB | FAIL by parameter count alone |
| latency p50 / p95 at 2048 px | 153 ms at 640 px on Mac CPU; no device run | <= 500 / 1500 ms | UNMEASURED |
| peak memory delta | not measured | <= 300 MB | UNMEASURED |
| thermals, battery, 5 s ceiling | not measured | section 6 | UNMEASURED |

Consequence: neither D1 model satisfies Phase 4 as written. RF-DETR-Nano clears
four of five accuracy criteria but cannot reach the 15 MB int8 budget, because
its 28.9M parameters alone exceed 15 MB at one byte each. YOLOX-Nano reaches
about 1 MB as int8 but fails recall at every threshold on val. The false
positive rate is also 3.8x over budget for RF-DETR, and that is independent of
the size problem. Phase 4 therefore needs a decision (rescale or retrain YOLOX,
or formally revise a budget with justification recorded in docs/decisions.md)
before any model can be declared shippable. The Core ML conversion work below is
a feasibility check on RF-DETR, not a shipment path.

### Core ML conversion (2026-10-21)

Result up front: conversion works and runs on the ANE. Compression does not: every
package small enough to approach the size budget fails the numeric gate, so Core
ML does not resolve the Phase 4 conflict.

**Path.** rfdetr 1.11.2 ships its own Core ML exporter
(`RFDETR.export(format="coreml")`: `torch.export` then coremltools 9.0). It
rewrites deformable attention into a rank 5 path before lowering, so the two
`GridSample` nodes that were the historical blocker (deformable attention
sampling in the decoder cross attention, bilinear, `padding_mode=zeros`) did not
block the conversion. The exporter also patches two missing coremltools torch
op registrations (`aten.alias`, `aten.__and__`) and pins
`minimum_deployment_target` to iOS16, which matches the app floor. Conversion
succeeded on the first attempt in about 5 s, lowering to 740 MIL ops with no
custom ops. Tool: `tools/train/src/hold_train/export_coreml.py`.

**Package contract.** Input `tensors` float32 [1, 3, 640, 640] NCHW, RGB,
ImageNet normalized, same preprocessing as ONNX. Outputs `concat_2`
[1, 300, 4] normalized cxcywh (dets) and `linear_102` [1, 300, 2] logits
(labels). Those output names are internal MIL names, not a chosen contract, so
the parity tool maps them by shape and role rather than assuming position.

**Size and compression.** Uniform weight palettization on a float16 package,
fp16 activations, `coremltools.optimize.coreml.palettize_weights`:

| Variant | Size | Decision-space parity at 1e-3 |
|---|---|---|
| float32 | 104.4 MB | PASS |
| float16 | 51.6 MB | FAIL |
| int8 (8 bit palettized) | 26 MB | FAIL |
| int4 (4 bit palettized) | 13 MB | FAIL |

**Core ML versus ONNX parity**, five val images, same decision space as the torch
gate (hold scores and boxes of queries scoring at least 0.5):

| Package | compute units | max hold-score diff | max active box diff | Verdict |
|---|---|---|---|---|
| float32 | CPU_ONLY | 8.31e-4 | 8.79e-7 | PASS |
| float32 | ALL (CPU plus ANE) | 8.31e-4 | 8.94e-7 | PASS |
| float16 | CPU_ONLY | 2.96e-1 | 5.93e-1 | FAIL |
| int8 | CPU_ONLY | 4.54e-1 | 7.31e-1 | FAIL |
| int4 | CPU_ONLY | 9.77e-1 | inf | FAIL |

The drift is a tail effect, not a uniform shift. On the most sensitive val image
(56 active queries at confidence 0.5) median score drift is 2.0e-2 for float16 and
1.9e-2 for int8, while the worst single query moves 2.96e-1 and 4.54e-1. float16
keeps the detection count at 56, int8 drops 2 of 56, and int4 drops all 56 and
returns non-finite boxes. So int4 is unusable without argument, int8 is
borderline at the level of individual holds, and float16 is close in bulk but
still breaks a strict equivalence contract. The gate is an equivalence check
against torch, which is the right test for a deployment copy; it is not an
accuracy measure, and no compressed variant has a val accuracy number yet.

**Latency**, float32 package, M5 Mac, one photo, model already loaded: CPU_ONLY
median 95.1 ms; all compute units 43.6 ms median with a 41 to 50 ms warm range,
first call 4.16 s including load and specialization. That is well under the
500 ms p50 budget as a Mac proxy, but an A13 phone is unmeasured, and the first
call cost is the number that matters for the 2 s cold-load limit.

**Consequence.** The only parity-clean Core ML package is 104 MB float32. int8
lands at 26 MB against a 15 MB budget and does not pass parity; int4 fits at
13 MB and destroys the output. Core ML therefore removes one unknown (the model
converts and the ANE path is fast) without changing the shipment decision. YOLOX
remains structurally the friendlier graph (113 Conv, 110 Sigmoid, no GridSample,
no Softmax, no attention), so the conversion risk that just cleared for RF-DETR
was never the binding constraint there; accuracy is.

## 2026-10-22 - D1b: YOLOX-S scaling run

Why: after D1 no model satisfied Phase 4. RF-DETR met the accuracy thresholds
but was 12% over the false positive budget at the recall floor and could not
reach 15 MB at int8, while YOLOX-Nano fit size but reached precision 0.7168 when
recall hit 0.80. Scaling YOLOX was chosen (docs/decisions.md). YOLOX-S is 8.94M
parameters, dense convolutions, initialized from the official Apache-2.0 COCO
checkpoint (456 of 462 tensors matched, 99.7% of parameters, only the 80-class
head replaced). Same data, schedule, seed, and low-memory settings as the Nano
run.

Training completed all 40 epochs, best checkpoint at epoch 40. In-loop val:

| Epoch | COCO AP50 | COCO AP50:95 |
|---|---|---|
| 5 | 0.7877 | 0.5266 |
| 10 | 0.8113 | 0.5616 |
| 15 | 0.8213 | 0.5725 |
| 20 | 0.8231 | 0.5737 |
| 25 | 0.8242 | 0.5768 |
| 30 | 0.8245 | 0.5785 |
| 35 | 0.8331 | 0.5874 |
| 40 | 0.8377 | 0.6010 |

Against YOLOX-Nano's final 0.7807 / 0.5224, the gain is +0.057 AP50 and +0.079
AP50:95. The larger gain at the stricter IoU means better localization, not only
better ranking, which is the pattern that should reduce spurious boxes.

Export: artifacts/holds_detector_yolox_s_d1.onnx, 36,701,782 bytes, opset 17,
input `images` [1, 3, 640, 640] in 0..255, output `output` [1, 8400, 6] decoded
cxcywh pixels plus objectness and class score, same contract as the Nano export.
Torch versus ONNX parity PASS on 5 val images: max hold-score diff 8.92e-6, max
active-query box diff 1.43e-6.

Harness val at confidence 0.5, 591 images: precision 0.9380, recall 0.7656,
mAP@0.5 0.8709, false positives 1.9475 per image, median count error 4. That is
a clear improvement over Nano at the same threshold (0.9185 / 0.6725 / 0.8101 /
2.2978 / 5).

Full val operating curve:

| confidence | precision | recall | FP per image | median count error |
|---|---|---|---|---|
| 0.35 | 0.8808 | 0.8203 | 4.2741 | 2 |
| 0.40 | 0.9029 | 0.8050 | 3.3350 | 2 |
| 0.45 | 0.9209 | 0.7888 | 2.6108 | 3 |
| 0.50 | 0.9380 | 0.7656 | 1.9475 | 4 |
| 0.70 | 0.9809 | 0.5991 | 0.4501 | 11 |
| 0.80 | 0.9910 | 0.4273 | 0.1489 | 17 |

At confidence 0.40 YOLOX-S passes precision (0.9029), recall (0.8050), and mAP
(0.8709), which Nano never did. It still fails the false positive budget by
6.7x and the count error limit by 2x. At 0.70 the false positives pass (0.4501)
but recall collapses to 0.5991, so the acceptance region remains empty.

Comparison at the recall floor of 0.80:

| Model | confidence | precision | recall | FP per image | count error | int8 size |
|---|---|---|---|---|---|---|
| YOLOX-Nano | 0.20 | 0.7168 | 0.8019 | 12.2014 | 4 | about 1 MB |
| YOLOX-S | 0.40 | 0.9029 | 0.8050 | 3.3350 | 2 | about 9 MB |
| RF-DETR-Nano | about 0.765 | about 0.98 | about 0.80 | about 0.56, interpolated | about 3 | about 26 to 29 MB |

Reading: capacity scaling cut false positives at the recall floor by 3.7x versus
Nano (12.20 to 3.34) and raised mAP by 0.061, so the premise that capacity
limited accuracy was correct. The premise that capacity limited false positives
was not: the remaining gap is structural. RF-DETR is still about 6x closer to the
budget at the same recall, because set prediction emits one query per hold and
its duplicates are suppressed by construction, while YOLOX runs NMS at IoU 0.65
and leaves near-duplicate boxes that the metric counts. How much of the 3.34 is
duplicates is unmeasured; a stricter NMS is the cheap experiment, but it would
have to remove about 85% of the excess to reach 0.5.

Consequence: the size advantage (about 9 MB at int8, comfortably inside 15 MB)
is real, and the accuracy thresholds now pass at one operating point, but the
false positive criterion is further away than RF-DETR's. No test-split spend is
justified for this model, and the policy for a second spend is still unset.

## 2026-10-22 - False positive anatomy on val: the labels are the limit

Why: RF-DETR was chosen as the model to push on false positives, since it sits
closest to the budget at the recall floor (about 0.56 per image against 0.5).
Before spending another training run, the false positives were classified to see
whether duplicates, small spurious boxes, or background texture accounted for the
excess. The analyzer is committed at tools/eval/src/analyze_false_positives.ts
(pure filters in fp_filters.ts, unit tested; 50 harness tests green).

Operating point: confidence 0.765, IoU 0.5, 591 val images. Precision 0.9821,
recall 0.8054, 335 false positives (0.5668 per image), median count error 3.

Buckets, by what the box overlaps:

| Bucket | Rule | Count | Share |
|---|---|---|---|
| duplicate | IoU 0.5 or more with a true positive box or a claimed ground truth | 12 | 3.6% |
| near miss | best ground truth IoU 0.3 to 0.5 | 120 | 35.8% |
| loose | best ground truth IoU 0.1 to 0.3 | 49 | 14.6% |
| background | no ground truth within IoU 0.1 | 154 | 46.0% |

Duplicate suppression is not the problem: set prediction already does its job,
and the 12 duplicate boxes are 3.6% of the total.

Size and score: mean false positive area is 2,958 px2 with a median equivalent
side of 34.7 px, so these are not dust specks. Area bands are 51 boxes under 100
px2, 115 from 100 to 400, 83 from 400 to 1,600, 51 from 1,600 to 6,400, and 35 at
or above 6,400. Scores are 86 in 0.7 to 0.8, 176 in 0.8 to 0.9, and 73 in 0.9 to
1.0, so they are confident boxes, not threshold noise.

Deterministic post-processing sweeps at the same confidence:

| Fix | Setting | Precision | Recall | FP per image | Count error |
|---|---|---|---|---|---|
| none | | 0.9821 | 0.8054 | 0.5668 | 3 |
| dedupe | IoU 0.5 | 0.9826 | 0.8051 | 0.5499 | 3 |
| dedupe | IoU 0.3 | 0.9828 | 0.8024 | 0.5398 | 3 |
| area floor | 49 px2 | 0.9823 | 0.7904 | 0.5482 | 4 |
| area floor | 100 px2 | 0.9829 | 0.7151 | 0.4805 | 6 |
| edge filter | 2 px | 0.9827 | 0.7902 | 0.5364 | 4 |

No deterministic filter reaches 0.5 while holding recall at 0.80. The best
combination that keeps recall near the floor is dedupe at IoU 0.5 plus a 25 px2
floor, at 0.5499. Only 18 boxes (5.4%) touch the frame edge.

What the boxes actually are. Two visual audits were run on the dumped boxes,
cropping each one with ground truth overlaid in green:

- In 24 background false positives, about 20 sit on a visible hold or volume
  with no ground truth box on it. Three are wall edges, gaps, or a climber.
  One is ambiguous.
- The near miss boxes are the same holds with box extent disagreement, plus
  large volumes that are labelled with a different extent.

One image makes the mechanism explicit: blackcreed__781 has 27 ground truth
boxes and 37 false positives. Its labels are large overlapping regions (one
covers most of the wall), while the model emits tight per-hold boxes that are
visually correct. A tight box inside a large region scores well under IoU 0.5,
so every correct detection there counts as a false positive.

Concentration: the 10 worst images hold 80 of the 335 false positives (23.9%).
113 val images contain a ground truth box over 40,000 px2, and those images hold
53 false positives (15.8%). Across the split, 174 of 591 images have at least one
false positive. Ground truth geometry confirms the coarseness is a minority
overall: median annotation area is 402.8 px2 with a median maximum side of
23.4 px, 4.5% of annotations exceed 10,000 px2, and 0.65% exceed 40,000 px2.

Conclusion. The false positive budget on the merged public split measures
annotation completeness and annotation geometry, not model error. The model is
finding real holds that the labels omit, and tight correct boxes that the coarse
labels score as misses. This also means the count error criterion is not
measurable there: at the recall floor the model under-detects by 7.5 holds per
image, which is consistent with unlabelled holds inflating the ground truth
count as much as with genuine misses.

Consequence. No retraining and no post-processing is justified by this
measurement. Hard negatives would be actively harmful: they would train the
model to suppress the real holds that the labels miss. The false positive and
count error criteria must be measured on the Phase 0 dense own-gym eval set that
docs/requirements.md already requires (US-5: at least 200 photos, 1,500 labelled
instances, double annotation), where every hold on the wall is labelled with a
tight box. Until that set exists, those two criteria are unmeasured rather than
failed, and the D1 and D1b false positive numbers should not be compared against
the 0.5 limit.

## 2026-10-22 - Core ML compression revisited: the gate was wrong, not the quantization

Why: the 2026-10-21 Core ML entry recorded that float16, int8, and int4 packages
all fail the decision-space parity gate, which made the 15 MB budget look
unreachable for reasons of numeric sensitivity. Re-running the analysis found
two problems with that conclusion.

First, the per-query gate is not a decision metric. It takes the maximum hold
score difference over all 300 queries and the maximum box difference over
queries above the threshold on either side. Background queries sit near a sigmoid
of 0.5 and flip across the threshold on tiny numeric changes, and their boxes
carry no meaning, so a package can fail the gate while producing the same
detections. At 40 val images the float16 package shows a maximum score
difference of 0.845 and still agrees on 1300 of 1306 detections.

Second, the compression study was built on the float16 package, and float16
already fails the per-query gate. Every palettized variant inherited that
failure, so the comparison measured the base rather than the compression.

Two tools close the gap. parity_coreml.py --agreement decodes both runtimes into
detection sets and matches them greedily at IoU 0.5, which is the screen.
eval_coreml.py runs a package and the ONNX graph over a whole split with the same
decoder and matcher as the harness and reports precision, recall, mAP, false
positives per image, and median count error for both, which is the acceptance
test. export_coreml.py gained --from-package to compress an existing package
without re-exporting, --quantize-bits for per-channel linear quantization, and
--palettize-mode, --palettize-granularity, --palettize-group-size, and
--palettize-per-channel-scale.

Full val, 591 images, confidence 0.765, IoU 0.5, Core ML CPU_AND_NE on the M5:

| Package | Size | Precision | Recall | mAP@0.5 | FP per image | Count error | Median latency |
|---|---|---|---|---|---|---|---|
| ONNX float32, canonical | 109 MB | 0.9828 | 0.8085 | 0.9242 | 0.5465 | 3 | |
| Core ML float32 | 104.4 MB | 0.9828 | 0.8085 | 0.9242 | 0.5465 | 3 | 94.8 ms |
| Core ML float16 | 51.6 MB | 0.9826 | 0.8009 | 0.9174 | 0.5448 | 3 | 36.7 ms |
| Core ML int8, k-means, per tensor | 26.4 MB | 0.9822 | 0.7996 | 0.9167 | 0.5567 | 3 | 36.2 ms |
| Core ML int8, uniform, per tensor | 26.0 MB | 0.9831 | 0.7587 | 0.9063 | 0.5008 | 5 | 37.5 ms |
| Core ML int8, per-channel linear | 26.0 MB | not scored, 12.0% of detections change | | | | | |
| Core ML int4, k-means, per tensor | 13.4 MB | unusable, 7 detections against 324 | | | | | |

The ONNX row here differs from the harness report by about 0.003 recall because
onnxruntime Python and onnxruntime-node decode and match at float64 versus
float32; the two runtimes are scored by the same matcher inside eval_coreml, so
the deltas are what matter.

Reading:

- The Core ML float32 conversion is decision-identical to ONNX: zero difference
  on every metric. The conversion path is sound, and all loss comes from weight
  precision.
- float16 costs 0.76 points of recall and 0.68 of mAP. That is the price of the
  format, not of compression.
- int8 k-means per tensor costs 0.13 more recall points than float16 for half the
  size, so it is the best size and accuracy trade at the iOS16 floor.
- int8 uniform is a bad scheme on these weights: 5 points of recall and 2 counts
  of error worse than k-means at the same size. The earlier "int8 fails" result
  was uniform palettization, not int8 as such.
- int4 per tensor destroys the model, and both grouped-channel palettization and
  int4 linear quantization raise "supported since iOS18". The rfdetr exporter
  pins iOS16 and exposes no deployment target, so reaching 13 MB needs a custom
  exporter and an iOS18 floor.

Consequence: the smallest usable RF-DETR package at the iOS16 floor is 26.4 MB
int8 k-means, which misses the 15 MB bundled budget by 11 MB. The budget cannot
be met by compression settings at iOS16. The options were a budget change to about
30 MB, an iOS18 floor plus a custom exporter, or the YOLOX-S branch at about 9 MB
with its own accuracy profile. Resolved the same day: the bundled budget was
raised to 30 MB, so the 26.4 MB int8 k-means package fits (docs/decisions.md).
