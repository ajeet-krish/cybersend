# CyberSend Research Log

Last updated: 2026-10-19 (Phase 0)

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
