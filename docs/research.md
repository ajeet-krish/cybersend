# CyberSend Research Log

Last updated: 2026-10-19 (Phase 0)

Findings and open questions from spikes and literature checks. Spike checklist for Phase 0; fill results as spikes complete.

## Phase 0 Spike Checklist

| Spike | Question | Status | Notes |
|-------|----------|--------|-------|
| License: Roboflow hold model | Can we ship trained weights in a store build? | Open | Fallback: train on self-collected or permissive data; record license id in assets/models/manifest.json |
| License: hold detection model | Apache-2.0 path (YOLOX-Nano or RF-DETR-Nano) confirmed, dataset attributions recorded (Blackcreed CC BY 4.0, own photos, ClimbInst license review) | Open | Gate for Phase 4; Ultralytics AGPL excluded by user decision 2026-10-19; Kilter cut from roadmap so no board license spike remains (re-entry only with written permission) |
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
