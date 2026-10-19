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
