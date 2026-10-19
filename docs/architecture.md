# CyberSend Architecture

Last updated: 2026-10-19 (Phase 0, roadmap revision after user decisions)

Snapshot of the current design. Full DDL lives in docs/schema.sql. Decision history lives in docs/decisions.md.

## Overview

Local first bouldering tracker on React Native (Expo dev client), TypeScript strict, SQLite on device, zero accounts. Clean architecture layers: routes and screens depend on feature stores and repositories, repositories depend on a SQL executor port, domain logic is pure TypeScript with no native imports. Photos are tagged on a Skia canvas in normalized coordinates; ML (self trained Apache-2.0 hold detection, MoveNet pose) runs on device and writes through the same repositories. Device floor is iOS 16 on iPhone 11 and newer. An AI capability gate auto disables hold detection and pose on devices that fail the Phase 0 benchmark; core logging is never gated.

## Layering and Folder Structure

```
app/                        expo-router routes, thin screens only
  (tabs)/                   logbook, sessions, stats, settings
  climb/[id].tsx            climb detail
  session/[id].tsx          live session logging
  tag/[photo_id].tsx        hold tagging canvas
  dev/flags.tsx             runtime flag screen, non release builds only
src/domain/                 pure logic, no native imports
  models/                   Climb, Session, Attempt, Hold, Video, BoardProblem (board types dormant)
  grade/                    grade scales, rasch_lite fitting
  attempts/                 outcome rules (flash/send/project/fail)
  stats/                    aggregations over attempts and sessions
  validation/               zod schemas for import payloads
src/data/
  db/connection.ts          open pragmas, path layout
  db/executor.ts            SqlExecutor port plus op-sqlite adapter
  db/transaction.ts         with_transaction nesting helper
  db/migrations/            runner + 001_initial.ts, 002_*.ts ...
  repositories/             one file per aggregate, the only SQL surface
  mappers/                  row to domain and back
src/features/
  sessions/  photos/  tagging/  stats/   feature stores (zustand) + hooks
  ml/                       HoldDetector, PoseEstimator, preprocess, nms, manifest
  boards/                   BoardProvider seam, dormant (board integration deferred, no providers)
  backup/                   export_service, import_service, zip
src/ui/                     components, canvas/ (coords, hold_canvas, gestures), theme/
src/app/                    flags.ts, providers.tsx, di container
assets/models/              ONNX and TFLite files + manifest.json
eval/                       ML eval dataset manifest + reports
tools/                      fixtures, eval runner (boardlib pipeline dormant with the board seam)
e2e/flows/                  Maestro flows
docs/                       architecture, decisions, schema.sql, tests, research, reviews
```

Dependency rule: app -> features -> domain and data. domain imports nothing from data or ui. repositories return domain models. Screens and hooks never call SQLite directly.

## Data Layer

- Driver: op-sqlite behind the SqlExecutor port (see decisions.md D1).
- Pragmas at open: foreign_keys ON, journal_mode WAL, busy_timeout 5000.
- Migrations: ordered integer versions in src/data/db/migrations, each up(tx) runs in one transaction, recorded in schema_migrations, PRAGMA user_version mirrored. No down migrations; restore is the rollback path.
- Entities: gyms, walls, boards, board_problems (dormant, board integration deferred), climbs, holds, photos, videos, pose_keypoints, sessions, attempts, grade_norm_params, settings. Full DDL in docs/schema.sql.
- Key columns: sessions.rpe (1 to 10, nullable), attempts.outcome CHECK in flash/send/project/fail, attempts.fell_on_hold_id -> holds(id), attempts.attempt_no per (session_id, climb_id), climbs.is_active and is_archived (gym reset lifecycle), walls.angle_deg and boards.angle_deg, videos.retention_class and pose_status.
- Required indexes: attempts(climb_id), attempts(session_id), climbs(gym_id) plus supporting indexes on holds, photos, videos, pose_keypoints.
- All coordinates in holds and pose_keypoints are normalized 0..1 over the source image or frame.
- Transaction handling: with_transaction(fn) in src/data/db/transaction.ts, nested calls join the outer transaction. Multi table writes (log attempt, import, restore, media sweep) are single transactions. Repositories hold prepared statements per connection.

## Data Flow

```
screen (app/) -> feature store (zustand) -> repository (src/data) -> SqlExecutor -> SQLite
                     |                        |
                     v                        v
              domain services          files: photos/ videos/ backups/
              (grade, stats, attempts)  via expo-file-system

tagging:  photo file -> Skia decode -> canvas gestures -> holds rows (normalized, source=manual)
hold ML:  photo file -> Skia decode+resize -> preprocess.ts -> ONNX holds_detector -> nms -> holds (source=detection)
pose:     vision-camera frame processor -> fast-tflite MoveNet -> pose_keypoints rows -> fall analysis (domain)
backup:   all tables + media -> manifest.json + data.json + media/ -> .cybersend zip (fflate)
import:   zip -> validate (zod, schema_version) -> staging DB -> atomic swap
```

## Canvas and Coordinates

- Domain coordinates: x_norm, y_norm over the full source image, radius_norm over image width. Written only in normalized space.
- Display: fit_content_box(image_size, canvas_size) computes the aspect fit rect; Viewport {scale, translate_x, translate_y} maps content box to screen. Pure helpers in src/ui/canvas/coords.ts (unit tested).
- Gestures (react-native-gesture-handler): tap empty adds a hold, tap hold selects, pan on selected hold moves it, long press deletes with confirm, pinch zooms about focal point, two finger pan moves viewport. Hold pan has exclusive precedence over viewport pan via hit test in normalized space (radius_norm tolerance).
- Pixels exist only inside the ui layer. Inference preprocessing uses the same normalized convention.

## ML Pipeline

- assets/models/manifest.json describes each artifact: id, version, sha256, input spec, license id. Bundled with the binary, not fetched at runtime.
- Hold detection (Phase 4): the model artifact is holds_detector.onnx, self trained and licensed Apache-2.0 (YOLOX-Nano or RF-DETR-Nano trained on the Blackcreed CC BY 4.0 dataset plus own labeled gym photos). Ultralytics YOLO weights are excluded (AGPL). Primary runtime is onnxruntime-react-native with the CoreML execution provider, but that package is stale (1.24.3) with known Expo compatibility issues, so Phase 4 opens with a time boxed spike; the fallback is react-native-fast-tflite with the Core ML delegate on a TFLite export of the same self trained model. The HoldDetector contract is identical on either runtime: single shot photo inference, 640x640 letterbox input, NMS in TypeScript (src/features/ml/nms.ts). Preprocess (preprocess.ts) is pure typed array code shared with the Node eval harness; Skia only decodes and resizes to RGBA.
- Pose (Phase 5): primary path is live frame processors on react-native-vision-camera at 8 to 12 Hz with react-native-fast-tflite running MoveNet Lightning, keypoints streamed to pose_keypoints during recording. Fallback is expo-camera video plus expo-video-thumbnails frame sampling at 5 Hz. MediaPipe Tasks PoseLandmarker is the alternative if the Phase 0 spike shows a solid binding. No Python bridge anywhere.
- Capability gate (Phases 4 and 5): startup check of the Phase 0 benchmark result (stored in settings) plus thermal monitoring. Devices that fail the benchmark get hold detection and pose auto disabled with a settings notice; repeated failure or thermal pressure does the same. Manual tagging never depends on ML output.
- Eval harness: eval/dataset/manifest.json holds labeled images with normalized hold circles. tools/eval/run_hold_eval.ts runs the same self trained ONNX model in Node (onnxruntime-node, jpeg-js as devDependencies) and emits eval/reports/*.json with precision, recall, mean center error. Provisional gates: Phase 0 spike set 20 images, Phase 4 gate 50 images, precision >= 0.85, recall >= 0.75 at center tolerance of 2 radius. Pose gate: correct fall-on-hold attribution >= 0.70 on labeled clips. The eval harness keeps the ONNX export even if the app falls back to TFLite.
- Board data (deferred, dormant seam, tied to no phase): the BoardProvider interface in src/features/boards stays as a documented seam with no providers implemented. tools/pipeline/boardlib is dormant and stays build tool only if it ever returns. The board integration phase was cut from the roadmap on 2026-10-19 (docs/decisions.md); board generic schema fields (boards, board_problems, board_angle_deg) are retained so the feature can return without a migration overhaul.

## Feature Flags

- Build variants in app.config.ts extra: development, internal (personal TestFlight), release.
- src/app/flags.ts merges compile-time defaults per variant with runtime overrides in the settings table (key flags.override). Flags: video_capture, grade_normalization, ai_hold_detection, ai_pose_analysis, boulder_vision, and board_import which is dormant with the board seam and tied to no phase.
- BoulderVision is hard gated in release: route not registered, ML code not in the release bundle graph. ai_hold_detection and ai_pose_analysis ship off by default and toggle on via the hidden dev screen (app/dev/flags.tsx, non release only).
- Personal dogfooding happens on internal builds; release builds never expose experimental surfaces.

## Backup and Export

- Storage layout under the app document root: db/, photos/ (plus thumbs/), videos/, backups/, exports/. All stored uris are relative.
- Full backup is a .cybersend zip: manifest.json (app_version, schema_version, created_at, sha256 per media file), data.json (every table as ordered arrays), media/ (photos always, videos only when retention_class=keep or user opts in). fflate for zip, expo-crypto for hashes, expo-sharing and expo-document-picker for transport.
- CSV export (RFC 4180): attempts, sessions, climbs. JSON export is lossless and is the same payload as backup data.json.
- Import: validate with zod, check schema_version <= current, load into a staging DB, verify foreign keys, take a pre-import snapshot in backups/, then atomically replace the main DB and reconcile media files. Import report lists counts and skipped rows.
- Retention: video retention policy in settings (mode none/days/count/keep_all). Sweeper runs at app start after migrations and deletes expired video files plus their pose rows.

## Testing

See docs/tests.md. Summary: Jest for domain and repositories (repository tests run against node:sqlite through the SqlExecutor port), @testing-library/react-native for components and hooks with fake repositories, Maestro for e2e flows on an iOS dev build, and the eval harness for ML regression.

## Dependency Budget

Native modules outside Expo Go: op-sqlite (Phase 1), onnxruntime-react-native (Phase 4, gated on the time boxed spike), react-native-vision-camera and react-native-fast-tflite (Phase 5). If the spike fails, fast-tflite covers both hold detection and pose and the count drops to 3. Hard cap 5 native modules. Everything else is Expo SDK or pure TypeScript (zustand, zod, fflate). dev client rebuilds are expected per native module; EAS Build provides internal distribution.

## Phase Map

0 spikes (licenses, inference perf, eval set) with checklist in docs/research.md. 1 core schema, migrations, logbook, backup/export. 2 photo plus Skia manual tagging, fall-on-hold, stats dashboard (MVP gate). 3 rasch_lite grade normalization. 4 on-device hold detection with the self trained Apache-2.0 model. 5 BoulderVision video analysis behind feature flags. Board integration is cut from the roadmap; its schema and seam are dormant and tied to no phase (docs/decisions.md 2026-10-19).
