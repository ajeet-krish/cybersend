# CyberSend Decision Records

Last updated: 2026-10-19

Entry format: "## [Date], Phase [N]: [Title]" with Context, Decision, Rationale, Trade-offs. Commas replace dash separators to honor the no-dash convention in AGENTS.md.

## 2026-10-19, Phase 0 (overall): SQLite driver is op-sqlite

**Context:** Plan of record requires deciding between op-sqlite and react-native-quick-sqlite for the local database.

**Decision:** op-sqlite behind a thin SqlExecutor port (src/data/db/executor.ts). react-native-quick-sqlite rejected: maintenance mode, weaker momentum, no advantage on our workload.

**Rationale:** op-sqlite is actively maintained, has the fastest published benchmarks, sync and async JSI APIs, prepared statements, blob support, and an Expo config plugin for dev client builds. The port keeps Jest tests off native code entirely.

**Trade-offs:** Not part of the Expo SDK, so it costs one native module and a dev client rebuild per platform. The SqlExecutor port adds a small indirection layer. Accepted because dev client is already the baseline (plan of record).

## 2026-10-19, Phase 0 (overall): Expo Router, Zustand, repositories as source of truth

**Context:** Navigation, state, and data access patterns needed before Phase 1 scaffold.

**Decision:** expo-router for navigation, zustand for feature stores, repositories as the only data access surface. No TanStack Query (nothing to fetch from a network).

**Rationale:** expo-router is the Expo default, file based, and supports deep links later. Zustand is minimal and testable with plain hooks. Repositories give one place for transactions and mapping, and let screens depend on fakes in tests.

**Trade-offs:** Manual cache invalidation instead of an async cache library. Acceptable at single user local scale; revisit if sync ever ships.

## 2026-10-19, Phase 0 (overall): Skia for photo canvas and inference preprocessing

**Context:** Phase 2 needs a photo hold tagging canvas; Phase 4 needs image preprocessing for YOLOv8n.

**Decision:** @shopify/react-native-skia renders photo, holds, and viewport. Skia also decodes and resizes photos to RGBA buffers; the pure typed array preprocess (src/features/ml/preprocess.ts) does letterbox and normalization for both the app and the Node eval harness. (Phase 4 was planned as YOLOv8n at this date; superseded by the Apache-2.0 self trained model decision below.)

**Rationale:** One rendering and decode dependency covers canvas, overlays, and tensor prep. Pure preprocess code is unit testable and keeps eval harness and app numerically identical.

**Trade-offs:** Skia readPixels on large photos costs memory, so tagging downscales to max 2048 px on the long edge. Minor resize differences between Skia and the eval decoder are tolerated because eval measures end to end detector quality.

## 2026-10-19, Phase 0 (overall): expo-camera for photos, vision-camera for video analysis

**Context:** Plan of record asked for the Expo Camera versus react-native-vision-camera tradeoff.

**Decision:** Phase 2 photo capture uses expo-camera. Phase 5 video capture and live frame processing (numbered Phase 6 before the 2026-10-19 board cut) uses react-native-vision-camera with frame processors. Fallback for Phase 5 is expo-camera video plus expo-video-thumbnails sampling at 5 Hz.

**Rationale:** expo-camera covers stills with the least native surface area. Frame processors are only needed for live pose during recording; vision-camera is the only mature option there.

**Trade-offs:** Two camera stacks across phases, and vision-camera adds a native module plus frame processor plugin wiring. Accepted because stills dominate Phases 2 to 5 and video stays behind a flag.

## 2026-10-19, Phase 0 (overall): ONNX Runtime for hold detection, TFLite MoveNet for pose

**Context:** On-device inference choices per phase, with no Python bridge allowed.

**Decision:** Phase 4 hold detection: ONNX via onnxruntime-react-native with CoreML execution provider (planned as YOLOv8n at this date; the YOLOv8n plan was superseded on 2026-10-19 by the Apache-2.0 self trained YOLOX or RF-DETR decision below). Phase 5 pose (numbered Phase 6 before the board cut): MoveNet Lightning via react-native-fast-tflite in frame processors, MediaPipe Tasks PoseLandmarker as the alternative if the Phase 0 spike proves the binding. boardlib stays build-time only.

**Rationale:** ONNX matches the YOLOv8 export path and shares one model format with the Node eval harness (onnxruntime-node). fast-tflite is the most reliable path to per-frame pose on the UI thread. Model licenses are gated in Phase 0 (docs/research.md).

**Trade-offs:** Two inference runtimes in the app (ONNX plus TFLite) and roughly 20 MB of model assets. Accepted to avoid a risky all-in bet on one runtime for both workloads; re-evaluate in Phase 5 to see if ONNX pose is viable and TFLite can be dropped.

## 2026-10-19, Phase 0 (overall): Normalized coordinates at the domain boundary

**Context:** Holds, fall targets, and pose keypoints must survive photo re-edits, device changes, and export.

**Decision:** All persisted coordinates are normalized to 0..1 over the source image or video frame (x_norm, y_norm, radius_norm over image width). Pixel conversion happens only in src/ui/canvas/coords.ts.

**Rationale:** Resolution independent, export friendly, and one convention covers tagging canvas, detection output, and pose frames.

**Trade-offs:** Every UI layer must convert, and hit testing needs a tolerance in normalized space. Covered by pure, unit tested helpers.

## 2026-10-19, Phase 0 (overall): UUIDv4 text ids and ISO 8601 UTC text timestamps

**Context:** Id and time representation for a local database that must export and import cleanly.

**Decision:** UUIDv4 text primary keys (via expo-crypto.randomUUID) and ISO 8601 UTC text timestamps everywhere. attempt_no is a per (session_id, climb_id) integer maintained by the repository.

**Rationale:** Readable dumps, sortable text, portable across SQLite and JSON export, no epoch math in the domain.

**Trade-offs:** Slightly larger rows than integers and string comparison for sorting. Negligible at personal logbook scale.

## 2026-10-19, Phase 0 (overall): Ordered integer migrations, no down migrations

**Context:** Schema migrations required day one; registry risk list flagged missing migrations.

**Decision:** Numbered migration modules (001_initial.ts, 002_*.ts) each running up(tx) in one transaction, recorded in schema_migrations with PRAGMA user_version mirrored. No down migrations.

**Rationale:** Forward only keeps the runner trivial and matches the restore based rollback story (import a backup instead of un-applying schema).

**Trade-offs:** Developer ergonomics suffer during schema churn; mitigated by wiping local dev data freely. Users can never downgrade the app binary without restoring an older backup.

## 2026-10-19, Phase 0 (overall): Feature flags via build variant plus settings overrides

**Context:** BoulderVision and AI detection must be separable between personal and shipped builds.

**Decision:** app.config.ts extra defines development/internal/release variants. src/app/flags.ts merges per-variant compile-time defaults with runtime overrides in the settings table. BoulderVision routes and code are excluded from release bundles entirely; AI flags ship off. Hidden dev screen for toggles on non-release builds.

**Rationale:** Personal dogfooding on internal builds can flip AI and BoulderVision without recompiling, while release builds cannot even reach experimental code.

**Trade-offs:** Variant checks in the router and a small amount of dead code in internal builds. Accepted as the price for a single codebase.

## 2026-10-19, Phase 0 (overall): Backup as a .cybersend zip with staging import

**Context:** Registry risk: no backup story. Plan of record requires export/import for data safety.

**Decision:** Full backup is a zip (manifest.json, data.json, media/) produced with fflate, hashed with expo-crypto. Import validates with zod, loads into a staging DB, verifies foreign keys, snapshots the current DB into backups/, then atomically swaps. CSV export is a one-way convenience. Videos included only when retention_class=keep or user opts in.

**Rationale:** Single file users can move through the iOS share sheet into Files or iCloud Drive; staging swap makes import failure non destructive; zod gives typed validation of foreign payloads.

**Trade-offs:** Pure JS zip is slower on large video sets, and there is no automatic cloud sync (local first by design). Backups are manual plus an in-app rotating copy (last 3).

## 2026-10-19, Phase 0 (overall): Jest with a node:sqlite adapter for repositories, Maestro for e2e

**Context:** Test strategy for Expo/TypeScript where repositories wrap a native driver.

**Decision:** SqlExecutor port has a node:sqlite test adapter so repository and migration tests run in plain Jest. Domain logic is pure unit tests. Components and hooks use @testing-library/react-native with fake repositories. E2E is Maestro flows on an iOS dev build. ML regression runs in the Node eval harness.

**Rationale:** Fast hermetic CI without simulators for the bulk of tests; Maestro needs no native test harness and works with dev client builds.

**Trade-offs:** node:sqlite is not bit identical to op-sqlite (SQL dialect drift risk), mitigated by standard SQL only (no vendor extensions) and a smoke pass of the same flows in Maestro before each release.

## 2026-10-19, Phase 0 (overall): Kilter board integration cut from the roadmap

**Context:** Kilter Terms prohibit automated access, scraping, and copying. The Aurora API has been dead since March 2026. The planned board phase had no legal data path.

**Decision:** Cut board integration entirely. The roadmap renumbers to six phases (0 to 5): former Phase 6 BoulderVision becomes Phase 5, the board phase is gone. Board generic schema fields (boards, board_problems tables, board_angle_deg and related columns) are retained but tied to no phase. The BoardProvider seam in src/features/boards stays dormant with no providers. Re entry only with written permission.

**Rationale:** No compliant data source exists. Keeping the schema and seam costs nothing and lets the feature return without a migration overhaul if permission is ever granted.

**Trade-offs:** Dormant tables and a seam with no implementation. Accepted because schema churn on re entry would be far more expensive than a little dead structure.

## 2026-10-19, Phase 4: Hold detection model is Apache-2.0 self trained

**Context:** Ultralytics YOLO weights are AGPL and cannot ship in an App Store build without an enterprise license. Phase 0 US-1 required a license determination.

**Decision:** Train our own detector (YOLOX-Nano or RF-DETR-Nano) on the Blackcreed dataset (CC BY 4.0) plus own labeled gym photos, and ship it under Apache-2.0. Ultralytics weights are excluded from the project entirely. Runtime is onnxruntime-react-native primary with react-native-fast-tflite (Core ML delegate, TFLite export of the same model) as fallback; onnxruntime-react-native is stale (1.24.3) with known Expo issues, so Phase 4 opens with a time boxed spike.

**Rationale:** License clean for App Store with clear attribution. The HoldDetector interface (single shot photo inference, 640 letterbox, TypeScript NMS) is unchanged across runtimes, so the fallback swap is contained to the runtime adapter.

**Trade-offs:** Model quality depends on our own training data and effort, and the ORT spike can fail and cost a second export. Accepted because detection is an accelerator only; manual tagging is never blocked.

## 2026-10-19, Phase 0 (overall): Device floor is iOS 16 on iPhone 11 and newer

**Context:** Perf budgets and the App Store support window needed an explicit floor.

**Decision:** Minimum iOS 16, iPhone 11 (A13) and newer. AI capability gate: devices that fail the Phase 0 inference benchmark get hold detection and pose auto disabled (checked at startup and on thermal pressure), with a settings notice. Core logging always works on every supported device.

**Rationale:** A13 is the oldest chip with credible Core ML delegate performance for nano class detectors, and it matches the requirements benchmark baseline (iPhone 11 / A13 class).

**Trade-offs:** Older hardware is excluded entirely. Accepted because supporting pre-A13 devices for ML would blow the latency and memory budgets for negligible reach.

## 2026-10-19, Phase 4: App Store is the hard goal, licensing gates are Must

**Context:** App Store submission is the eventual hard goal (requirements decision 6), so release builds must satisfy App Review licensing and attribution rules.

**Decision:** Release-variant licensing gates for Phase 4 are Must priority, not Could: Apache-2.0 model license documented, dataset attributions (climbtag, blackcreed, and pwals, each CC BY 4.0, plus own gym photos) shown in settings/about and recorded in assets/models/manifest.json, and both verified in the Phase 4 definition of done. AI features stay behind the flag plus capability check in every variant.

**Rationale:** Attribution obligations travel with CC BY 4.0 and Apache-2.0, and discovering them at review time is expensive. Making licensing a Must folds it into the ship gate instead of a late cleanup task.

**Trade-offs:** Extra settings surface and manifest bookkeeping in Phase 4. Accepted for a clean and predictable review path.

## 2026-10-19, Phase 0 (overall): Full native iOS migration is the app stack

**Context:** The React Native (Expo) plan of record leaned on a fragile native module surface (op-sqlite, onnxruntime-react-native, vision-camera, fast-tflite) with no cross-platform payoff, because the user confirmed iOS only forever. The user produced a native draft (Swift, SwiftUI, GRDB, Core ML) and approved a full native migration anchored to our approved docs, schema, requirements, and ML track. The author is new to Swift.

**Decision:** Nine explicit user decisions. (1) Full native migration now: Swift, SwiftUI with UIKit gestures for the canvas, GRDB, Core ML, AVFoundation. (2) Because Swift fluency is new, the plan carries a velocity checkpoint after the data-layer port and before any UI work; progress is reviewed with the user there, and the fallback to keeping the React Native app (option c) stays on the table only through M0. (3) iOS only forever; Android is dead, not deferred. (4) The goal is app performance and polish (native craft); training is unaffected and stays PyTorch MPS on the M5. (5) Rejected from the native draft: bundled Kilter catalog (license), YOLOv8 .mlmodel (AGPL), the draft's stale schema (our approved schema with migrations wins). (6) Adopted from the draft: SwiftUI plus UIKit canvas gestures, GRDB, VNCoreMLRequest with .cpuAndNeuralEngine plus the Xcode Core ML performance report to verify ANE placement, AVFoundation (AVCaptureSession, AVAssetReader) for Phase 5 video, Vision body pose as a spike candidate benchmarked against TFLite/MoveNet in the Phase 0 pose spike, and the coremltools conversion pipeline. (7) Model bias shift: the ML-D1 comparison now scores Core ML conversion risk as a column, biasing toward YOLOX-Nano (conv only, safe conversion) over RF-DETR (90 partitions, GPU-only 61 ms on iPhone 14 Pro, FP16 grid_sample failure). ONNX remains the canonical training and eval format; the .mlmodel is a deployment copy behind a parity gate (same frozen-split images, box delta <= 1 px, logit delta recorded). (8) Migration plan M0 to M6: M0 decision lock (TypeScript committed as the port spec, Xcode project with iOS 16 floor, GRDB DatabaseMigrator, swift-testing with in-memory GRDB, ported migration tests), M1 domain plus data plus backup port (byte-compatible .cybersend, golden fixtures shared with tools/eval), M2 SwiftUI logbook, M3 photo and tagging MVP with the Phase 2 gate unchanged, M4 grade normalization port, M5 hold detection (coremltools plus parity and eval gates 0.85/0.80/0.75), M6 BoulderVision behind the experimental flag. All US numbers and budgets from docs/requirements.md carry over unchanged. (9) Stack-independent survivors: tools/train, tools/eval, datasets, licenses, docs, feature flags, capability gate, preprocess golden vectors (letterbox 640, pad 114, ImageNet normalization), and the normalized-coordinate contract.

**Rationale:** With Android dead the cross-platform argument for React Native is gone, and native buys performance, polish, direct Core ML and AVFoundation access, and removes the stale native module risk list (onnxruntime-react-native 1.24.3 with known Expo issues). Anchoring the migration to the approved schema, requirements, and ML track keeps all validation work intact. Scoring Core ML conversion risk in ML-D1 avoids adopting a model whose documented conversion pitfalls make it expensive to ship.

**Trade-offs:** New-to-Swift velocity loss and a rewrite cost up front; mitigated by the velocity checkpoint and the option (c) fallback open through M0. Two model artifacts per release (canonical ONNX plus .mlmodel) with a parity gate to maintain. GRDB DatabaseMigrator tracks its own grdb_migrations table; it is the runner, and each migration block also writes a schema_migrations audit row so US-7's audit format and portable dumps survive, and if that proves awkward grdb_migrations alone is the accepted change with a note against US-7. Vision pose accuracy is well below BlazePose per Google's benchmark, so pose stays gated on our own spike measurements.

## 2026-10-19, Phase 0 (M0): schema reconciliation

**Context:** docs/reviews.md flagged MAJOR drift between docs/requirements.md section 2 and the Phase 1 draft docs/schema.sql (grade storage, hold role fields, fell_on_hold_id naming, gym archive semantics). The M0 native migration needs one authoritative v1 DDL before Swift Migration 001 is written. The user decided the mapping: requirements wins on every contested field, and docs/schema.sql is rewritten to the final v1 DDL.

**Decision:** docs/schema.sql v1 is reconciled with this old to new mapping. (1) Grade storage: old denormalized climbs.grade_system (text, default 'v_scale') plus climbs.grade_raw (level id text) become normalized grade_systems and grade_levels tables; climbs references grade_system_id (NOT NULL, default 'v_scale', FK RESTRICT) plus grade_level_id (nullable, FK SET NULL); grade levels carry rank_order and color_hex; Migration 001 seeds the built-in V scale (v0 to v17) and Fontainebleau (f1 to f9a, ids with '+' rendered as _plus). Custom schemes become is_builtin = 0 rows instead of settings JSON. (2) Holds: old holds.label plus holds.color become holds.role (nullable, CHECK in start, intermediate, top per US-19) plus holds.color_family. (3) Attempts: old attempts.fell_on_hold_id becomes attempts.fall_on_hold_id (the requirements name everywhere, domain property fallOnHoldId), and old attempts.created_at (which held the attempt moment) becomes attempts.attempted_at per requirements section 2. (4) Gyms: old gyms.is_active (1 = active) becomes gyms.is_archived (0 = active) per requirements section 2, so gym archival reads positively. (5) Unchanged: sessions started_at, ended_at, rpe checks; climbs is_active plus is_archived; walls keep is_active (not contested); boards and board_problems stay dormant; grade_norm_params stays for M4; schema_migrations stays as the US-7 audit table that each migration also writes to. The frozen TypeScript tree (src/) keeps the old names, as it does everywhere; the Swift port implements the reconciled schema and is the runner of record going forward.

**Rationale:** One authoritative schema before the native data layer lands avoids baking the drift into Migration 001 and into every Swift mapper. The graded references make US-9 ("grade stored as (scheme_id, level_id), never free string") enforced by foreign keys instead of convention, and the renamed columns read like the requirements, which is what every future doc and review will check against.

**Trade-offs:** The TS spec's repositories, mappers, and validation tables now visibly diverge from docs/schema.sql, and any M1 byte-compatibility fixture work must translate old names to new (falls and holds on export import). Deleting or re-grading through normalized tables costs two foreign keys of bookkeeping instead of two text columns. Accepted; the migration record plus the frozen spec commit keep both worlds explainable.

**Superseded records (kept for history, this file is append-only):** The React Native stack records of 2026-10-19 are superseded as follows. "SQLite driver is op-sqlite" (now GRDB). "Expo Router, Zustand, repositories as source of truth" (repositories survive; navigation and stores move to SwiftUI). "Skia for photo canvas and inference preprocessing" (canvas moves to SwiftUI plus UIKit gestures; preprocess golden vectors survive). "expo-camera for photos, vision-camera for video analysis" (now AVFoundation). "ONNX Runtime for hold detection, TFLite MoveNet for pose" (now Core ML; ONNX remains the canonical eval format; pose candidates are Vision versus TFLite/MoveNet). "Feature flags via build variant plus settings overrides" (now Swift build configurations plus settings rows). "Jest with a node:sqlite adapter for repositories, Maestro for e2e" (now swift-testing with in-memory GRDB). "Ordered integer migrations, no down migrations" (adapted to DatabaseMigrator named migrations with schema_migrations audit rows; forward-only with no down migrations survives). "Backup as a .cybersend zip with staging import" survives as a format decision with the implementation ported to Swift.

## 2026-10-19, Phase 0 (M1): Rotating backup retention is last 10

**Context:** The backup decision record above says the in-app rotating copy keeps the "last 3", while docs/requirements.md US-15.2 and open question 2 both say app-local rotation keeps the last 10 (the frozen TypeScript service also keeps 10).

**Decision:** Requirements win: the Swift BackupService keeps maxBackupsKept = 10, matching the TypeScript port spec. The "last 3" wording above is superseded on this point.
