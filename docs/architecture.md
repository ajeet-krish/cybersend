# CyberSend Architecture

Last updated: 2026-10-19 (Phase 0, full native iOS migration)

Snapshot of the current design after the native migration decision (docs/decisions.md, 2026-10-19). Full DDL lives in docs/schema.sql. The TypeScript tree (src/ and app/) is frozen and serves as the behavioral port spec for the Swift port.

## Overview

Local first bouldering tracker, native iOS only, written in Swift. SwiftUI screens with UIKit gesture recognizers on the tagging canvas, GRDB over SQLite for storage, Core ML for on-device inference, AVFoundation for video. Zero accounts, hard offline. The approved schema, requirements (US numbers and budgets), ML training track, licenses, and the normalized-coordinate contract carry over unchanged from the React Native plan; only the application stack is replaced. Device floor is iOS 16 on iPhone 11 and newer, with the AI capability gate unchanged.

## Component Breakdown

| Component | Responsibility | Location |
|-----------|---------------|----------|
| Domain | Entities, grade normalization (rasch_lite), attempt rules, stats, import validation. Pure Swift, no GRDB or UIKit imports. | ios/Sources/Domain |
| Data | GRDB database, migrations, repositories, row records and mappers, backup serialization. The only SQL surface. | ios/Sources/Data |
| Features | Session logging, photos, tagging, grade normalization, ML adapters (hold detection, pose), backup and import, feature flags, dormant board seam. | ios/Sources/Features |
| UI | Theme, shared SwiftUI views, canvas coordinates and hold rendering, UIKit gesture layer. | ios/Sources/UI |
| Tests | swift-testing suites. DataTests run against in-memory GRDB. | ios/Tests |
| ML tooling | Dataset build, training, ONNX export, eval harness. Stack independent, unchanged. | tools/train, tools/eval |
| Port spec | Frozen TypeScript implementation. Behavioral reference and source of golden fixtures. | src/, app/ |
| Model assets | Canonical ONNX plus Core ML deployment copies with manifest.json. | assets/models/ |

Dependency rule: Features depend on Domain and Data; UI renders domain values and calls Features. Domain imports nothing from Data or UI. Repositories return domain models. Views never touch GRDB directly.

## Data Flow

```
training:  tools/train (PyTorch MPS on the M5) -> frozen splits -> holds_detector_d1.onnx (CANONICAL)
convert:   ONNX -> coremltools -> holds_detector.mlmodel (deployment copy, never canonical)
parity:    same frozen-split images through ONNX and .mlmodel
           box delta <= 1 px, logit delta recorded -> parity gate -> bundle in app
hold ML:   photo -> CGImage -> VNCoreMLRequest (.cpuAndNeuralEngine) -> nms -> holds (source=detection)
pose:      AVFoundation frames (AVCaptureSession, AVAssetReader) -> Vision pose or TFLite/MoveNet
           (Phase 0 pose spike chooses) -> pose_keypoints rows -> fall analysis (Domain)
tagging:   photo -> canvas (SwiftUI + UIKit gestures) -> holds rows (normalized, source=manual)
runtime:   SwiftUI view -> feature store (Features) -> repository (Data) -> GRDB -> SQLite
           files: photos/ videos/ backups/ via FileManager
backup:    all tables + media -> manifest.json + data.json + media/ -> .cybersend zip
import:    zip -> validate -> staging DB -> foreign key check -> atomic swap
```

## File Structure

| Path | Purpose |
|------|---------|
| ios/CyberSend.xcodeproj | Xcode project. iOS 16 deployment target. Build configurations: development, internal, release. |
| ios/Sources/Domain/ | Models, grade, attempts, stats, validation. Port of src/domain with identical behavior. |
| ios/Sources/Data/ | GRDB setup, DatabaseMigrator migrations, repositories, records and mappers, backup serialization. Port of src/data. |
| ios/Sources/Features/ | Sessions, photos, tagging, ml (HoldDetector, PoseEstimator, preprocess, nms), grade, backup, boards (dormant), flags. |
| ios/Sources/UI/ | Theme, shared SwiftUI views, canvas (coords, hold views, UIKit gestures). |
| ios/Tests/ | swift-testing suites mirroring the Jest suites; in-memory GRDB for DataTests. |
| src/, app/ | Frozen TypeScript port spec. Never built into the app. Reference for behavior and fixtures. |
| tools/eval/ | ML eval harness over frozen splits, reports. Unchanged. |
| tools/train/ | Dataset build, D1 training, ONNX export, license records. Unchanged. |
| assets/models/ | holds_detector.onnx (canonical), holds_detector.mlmodel (deployment copy), manifest.json. |
| docs/ | architecture, decisions, schema.sql, requirements, tests, research, reviews. |

## Data Layer

- Driver: GRDB 7 over the system SQLite.
- Migrations: GRDB DatabaseMigrator runs named forward migrations (001_initial and so on), one transaction per migration, tracked in grdb_migrations. No down migrations; restore is the rollback path.
- Migration audit: grdb_migrations is the runner's source of truth. Each migration block also inserts one row into schema_migrations (version, name, applied_at) in the same transaction, keeping the US-7 audit format and portable dumps shared with the TypeScript port spec. If dual bookkeeping proves awkward, grdb_migrations alone is the accepted change with a note against US-7.
- Pragmas at open: foreign_keys ON, journal_mode WAL, busy_timeout 5000.
- Entities: gyms, walls, boards, board_problems (dormant, board integration cut), climbs, holds, photos, videos, pose_keypoints, sessions, attempts, grade_norm_params, settings. DDL unchanged in docs/schema.sql.
- Key columns and indexes: unchanged (attempts.outcome CHECK in flash/send/project/fail, attempts.fall_on_hold_id, attempt_no per (session_id, climb_id), climbs.is_active and is_archived, wall and board angles, videos.retention_class and pose_status; indexes on attempts(climb_id), attempts(session_id), climbs(gym_id)).
- All coordinates in holds and pose_keypoints are normalized 0..1 over the source image or frame.
- Transactions: a withTransaction helper on the GRDB writer; nested calls join the outer transaction. Multi table writes (log attempt, import, restore, media sweep) are single transactions.

## Migration Plan (M0 to M6)

| Milestone | Scope | US mapping | Gate |
|-----------|-------|-----------|------|
| M0 | Decision lock. Commit the TypeScript tree as the frozen port spec. Xcode project with iOS 16 floor. GRDB DatabaseMigrator wiring. swift-testing plus in-memory GRDB harness. Port the migration tests. | US-6, US-7 (setup) | Data layer port complete, then the velocity checkpoint: the user reviews progress; fallback to the React Native track (option c) stays open until this checkpoint closes with M0 sign-off. |
| M1 | Domain, data, and backup port. Byte-compatible .cybersend archives. Golden fixtures shared with tools/eval. | US-7, US-13 to US-16 | Import and export round trips between the TypeScript spec and the Swift port in tests. |
| M2 | SwiftUI logbook: gyms, grade schemes, climbs, sessions, attempts, quick-log, settings shell. | US-8 to US-12, US-25 | Quick-log budget: <= 4 taps, <= 5 s. |
| M3 | Photo capture and tagging MVP. The Phase 2 gate is unchanged. | US-17 to US-26 | MVP ship gate exactly as written in requirements section 4. |
| M4 | Grade normalization port: rasch_lite, translator, data-sufficiency gate. | US-27 to US-30 | Statistical thresholds on the synthetic fixture. |
| M5 | Hold detection: coremltools pipeline, parity gate, eval gates. | US-31 to US-35 | Precision >= 0.85, recall >= 0.80, mAP@0.5 >= 0.75 on the frozen test split, plus all Phase 4 perf budgets. |
| M6 | BoulderVision video analysis behind the experimental flag. | US-36 to US-40 | Phase 5 budgets; if any budget misses the feature stays flagged off and is marked not shipped. |

All US numbers and numeric budgets from docs/requirements.md carry over unchanged. The Phase 0 spikes (licenses, inference perf, pose runtimes, eval set) continue under the ML phase numbering and feed M5 and M6.

## ML Pipeline

- Training and export are unchanged in tools/train (PyTorch MPS on the M5). ONNX is the canonical artifact for training, evaluation, and parity.
- Conversion: coremltools turns the chosen ONNX into a .mlmodel deployment copy. Parity gate runs the same frozen-split images through both: box delta <= 1 px, logit delta recorded. Only a passing .mlmodel ships in the app bundle.
- Runtime: VNCoreMLRequest with .cpuAndNeuralEngine. ANE placement is verified with the Xcode Core ML performance report before M5 acceptance. NMS stays in Swift.
- Model bias: the ML-D1 comparison scores Core ML conversion risk as a column. YOLOX-Nano (conv only) is the low-risk default. RF-DETR carries documented conversion costs (90 partitions, GPU-only 61 ms on iPhone 14 Pro, FP16 grid_sample failure).
- Pose: Vision body pose is a spike candidate only, benchmarked against TFLite/MoveNet in the Phase 0 pose spike (Google's benchmark shows Vision well below BlazePose). No climbing-specific accuracy claims without our own data. No Python bridge anywhere.
- Capability gate: unchanged. Startup benchmark result plus thermal monitoring; failing devices get hold detection and pose auto disabled with a settings notice. Core logging is never gated. Manual tagging never depends on ML output.
- Eval harness: tools/eval is unchanged and stays the source of truth for detector quality. Gates follow docs/requirements.md section 6 on the frozen splits, with the US-5 self-collected test split for acceptance.

## Canvas and Coordinates

- Domain coordinates: x_norm, y_norm over the full source image, radius_norm over image width. Written only in normalized space; pixels exist only inside the UI layer.
- Display: fit_content_box and a Viewport (scale, translate_x, translate_y) map content to screen. Pure helpers, unit tested, ported from src/ui/canvas/coords.ts.
- Gestures: UIKit gesture recognizers on the SwiftUI canvas view. Tap empty adds a hold, tap hold selects, pan on a selected hold moves it, long press deletes with confirm, pinch zooms about the focal point, two finger pan moves the viewport. Hold pan has exclusive precedence over viewport pan via hit test in normalized space (radius_norm tolerance).
- Inference preprocessing uses the same normalized convention and the shared golden vectors (letterbox 640, pad 114, ImageNet normalization).

## Feature Flags

- Build configurations in the Xcode project: development, internal (personal TestFlight), release, each with xcconfig compile-time defaults.
- Runtime overrides live in the settings table and merge in a FeatureFlags type under ios/Sources/Features/Flags. Flags: video_capture, grade_normalization, ai_hold_detection, ai_pose_analysis, boulder_vision, board_import (dormant with the board seam, tied to no phase).
- BoulderVision is hard gated in release: compiled out via configuration checks and unreachable in release navigation. ai_hold_detection and ai_pose_analysis ship off by default and toggle on via a hidden dev screen on non-release builds.
- Personal dogfooding happens on internal builds; release builds never expose experimental surfaces.

## Backup and Export

- Storage layout under the app document root: db/, photos/ (plus thumbs/), videos/, backups/, exports/. All stored uris are relative.
- Full backup is a .cybersend zip: manifest.json (app_version, schema_version, created_at, sha256 per media file), data.json (every table as ordered arrays), media/ (photos always, videos only when retention_class=keep or the user opts in). The format is byte-compatible with the TypeScript port spec (M1 golden fixtures). Hashes via CryptoKit.
- CSV export (RFC 4180): attempts, sessions, climbs. JSON export is lossless and matches backup data.json.
- Import: validate, check schema_version <= current, load into a staging DB, verify foreign keys, take a pre-import snapshot in backups/, then atomically replace the main DB and reconcile media. Import report lists counts and skipped rows.
- Retention: video retention policy in settings (mode none/days/count/keep_all). Sweeper runs at app start after migrations.

## Test Strategy

- swift-testing for all Swift code. DomainTests and DataTests port the Jest suites one to one; DataTests run on in-memory GRDB, which removes the node:sqlite dialect-drift risk of the React Native plan.
- Import/export round-trip tests (US-14, US-16) use golden .cybersend fixtures shared with the TypeScript port spec in both directions.
- Preprocess golden vectors (letterbox 640, pad 114, ImageNet normalization) are shared with tools/eval; the Swift port must match within a recorded tolerance.
- ML regression stays in tools/eval (unchanged): precision, recall, mAP@0.5 at IoU 0.5, false positives per image, hold-count error, with the 0.85/0.80/0.75 gates on the frozen test split.
- E2E tooling is decided at M2; XCUITest is the default candidate. The Maestro flows do not carry over.

## Risks and Mitigations

- New to Swift velocity. Mitigation: the M0 velocity checkpoint after the data-layer port and before any UI work, with the option (c) fallback (keep the React Native app) open until the checkpoint closes. The frozen TypeScript spec keeps behavior unambiguous during the port.
- RF-DETR Core ML conversion (90 partitions, GPU-only 61 ms on iPhone 14 Pro, FP16 grid_sample failure). Mitigation: ML-D1 scores conversion risk as a column, biasing to YOLOX-Nano; if RF-DETR still wins on quality, budget for the documented FP32 and partition work.
- Vision pose accuracy well below BlazePose. Mitigation: Vision is a spike candidate benchmarked against TFLite/MoveNet in the Phase 0 pose spike; no accuracy claims without own-data measurement; pose stays behind the experimental flag.
- GRDB grdb_migrations versus our schema_migrations audit table. Decision: DatabaseMigrator is the runner and each migration also writes a schema_migrations audit row in the same transaction (trivial in practice). If dual bookkeeping drifts, drop to grdb_migrations alone and note the change against US-7.
- Core ML ANE placement unverified. Mitigation: VNCoreMLRequest with .cpuAndNeuralEngine plus the Xcode Core ML performance report, verified per model before M5 gates.
- ONNX to Core ML parity drift. Mitigation: the .mlmodel is a deployment copy only, bundled only after the parity gate (same frozen-split images, box delta <= 1 px, logit delta recorded).

## Stack-Independent Survivors

tools/train, tools/eval, datasets, license records, docs, the feature flag model, the AI capability gate, preprocess golden vectors (letterbox 640, pad 114, ImageNet normalization), and the normalized-coordinate contract all survive the migration untouched. Board integration remains cut, with board-generic schema fields and the BoardProvider seam dormant and tied to no phase (docs/decisions.md 2026-10-19).

## Phase Map

The requirements phases 0 to 5 are delivered through milestones M0 to M6 as mapped above: 0 spikes feed M5 and M6, 1 core foundation lands in M0 to M2, 2 photo and tagging MVP is M3, 3 grade normalization is M4, 4 hold detection is M5, 5 BoulderVision is M6.
