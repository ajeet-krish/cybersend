# CyberSend Decision Records

Last updated: 2026-10-21

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

## 2026-10-20, Phase 0 (M2): app target is a committed Xcode project over the local package

**Context:** M2 needs an iOS app target. Options: XcodeGen or similar tooling, a generated-then-discarded project, or a hand-authored committed .xcodeproj consuming the existing ios/ Swift package.

**Decision:** Commit ios/CyberSend.xcodeproj (objectVersion 77, file-system synchronized groups) with targets CyberSend (bundle id com.cybersend.app, iPhone only, iOS 16.0 floor, Swift 6 language mode), CyberSendAppTests, and CyberSendUITests. The project references the local package at ios/ itself (XCLocalSwiftPackageReference, relativePath "."); app sources live in ios/App, config in ios/Config with Development, Internal, Release xcconfig files. Info.plist is explicit (reviewable), not generated.

**Rationale:** Synchronized groups mean new Swift files never touch project.pbxproj, which keeps the hand-authored file small and stable. Reusing ios/ as the package keeps the verified swift build and swift test commands unchanged. No third-party project tooling is introduced.

**Trade-offs:** Hand-authored pbxproj can drift or break; mitigated by xcodebuild -list and plutil -lint checks and a minimal file. The project sits inside the package directory; if Xcode ever refuses the self-reference, the package moves to ios/CyberSendCore and commands and docs update (one-time churn).

## 2026-10-20, Phase 0 (M2): ObservableObject per-feature stores, iOS 16 constraints

**Context:** State management for the SwiftUI logbook with an iOS 16 floor. @Observable (Observation) is iOS 17 plus and cannot be the baseline.

**Decision:** Per-feature stores (LogbookStore, SessionDetailStore, GymsStore, GradeSchemesStore, SettingsStore) are @MainActor ObservableObject classes with @Published state in ios/Sources/Features/Logbook, calling repositories synchronously on the main actor, refreshing on appear and after each write. Views observe stores via @StateObject or @EnvironmentObject. No third-party state or navigation libraries; NavigationStack plus TabView with typed route enums per tab.

**Rationale:** Stores stay unit testable against in-memory GRDB inside the existing swift-testing harness (no simulator needed), and ObservableObject works on iOS 16 and macOS alike. Synchronous repository calls on the main actor match the measured personal-scale performance (backup of 5000 attempts measured 0.59 s).

**Trade-offs:** Manual refresh discipline instead of observation-based invalidation; main-actor database calls instead of async pipelines. Accepted at single-user scale; heavy paths (backup write) run in detached tasks with Sendable values only. If iOS 17 becomes the floor later, stores can adopt @Observable without API changes.

## 2026-10-20, Phase 0 (M2): storage root is Application Support, quick-log lives on the open session screen

**Context:** M2 wiring needs two conventions: where files live (architecture said "app document root") and where the quick-log flow lives (the frozen spec logs attempts on app/session/[id].tsx).

**Decision:** The storage root is Application Support/CyberSend/ (db/, photos/, videos/, backups/, exports/), invisible to the Files app; backups travel out only through the share sheet. Quick-log is the open session screen: choose climb, tap outcome (the tap saves), project and fail prompt for the fall hold with a skip; the Logbook climb rows keep the spec behavior of opening climb detail. Appearance preference (system, light, dark) and photo retention preference (keep originals default) are new settings keys, export safe because settings rows are free-form.

**Rationale:** Application Support keeps users out of raw database files and matches the local first, share-sheet based backup story. The session screen as quick-log surface keeps the frozen flow and fits the 4 tap budget (at most 4 taps cold, 2 to 3 warm).

**Trade-offs:** Backups are unreachable from the Files app without the share sheet (acceptable; the share sheet is the defined F4 path). The fall-hold picker is a stub until M3 tagging gives climbs holds, so M2 fall_on_hold_id is null in practice. Update of the architecture wording from "document root" to Application Support recorded here.

## 2026-10-20, Phase 0 (M2): M2 housekeeping scope and XCUITest as the e2e tool

**Context:** The M1 review left follow-ups (raw PRAGMA in Features, non-atomic writes, export uri guard, zip caps, throttle timestamp parsing), and architecture left the e2e tool undecided until M2.

**Decision:** M2 lands all of the following before UI work: foreign_key_check moves into DumpRepository (repositories-only SQL), Data.write gains .atomic, export media reads skip unsafe relative uris, BackupArchive unpack caps entry count and total inflated bytes (10000 entries, 4 GB), and the throttle clock accepts ISO timestamps with or without fractional seconds and fails explicitly on an unparseable injected now. Deferred: the jsNumberString band documentation (whenever cross-port byte fixtures need those bands) and migratePayload revalidation polish. XCUITest is the e2e tool; the smoke set is three tests with Debug-only launch-argument seeding.

**Rationale:** Restore becomes user reachable in M2 (settings), so archive hardening belongs in M2, not later. Housekeeping lands first so review debt does not compound behind new UI. XCUITest is first-party, runs in the same xcodebuild test command as unit tests, and fits a three-flow smoke budget.

**Trade-offs:** Zip caps could reject absurdly large legitimate archives (4 GB inflated is far above real personal backups). XCUITest is slower and flakier than unit tests, mitigated by keeping it to three deterministic smoke flows.

## 2026-10-20, Phase 2 (M2): US-26.1 per-climb grade history defers to M4 (historical stats)

**Context:** US-26.1 records every re-grade with an effective date so historical stats can state which grade was in effect. M2's logbook hard constraint is zero new tables: the export payload must stay byte compatible with the frozen TypeScript spec (M1 review obligations and the M2 export parity gate), and no consumer of a grade history timeline exists before the stats milestone.

**Decision:** Defer US-26.1 to M4 (historical stats). M2 stores only the current grade per climb (level id), matching the frozen schema. Scope of the deferral: no grade history table, no effective date column, no history UI, and exports carry only the current grade; a re-grade overwrites the stored level in place. US-26.2 (archive is the default reset workflow) and US-26.3 (deleting a climb with attempts stays blocked, archive only) are unaffected in M2.

**Revisit trigger:** M4 start, when historical stats need the timeline. The history table lands then as a schema migration with a payload migration step (currentVersion bump plus payloadMigrations), so older exports still import; US-26.1 acceptance (each re-grade queryable with the date it stopped being current) carries over unchanged.

## 2026-10-20, Phase 2 (M3): photo capture is PhotosPicker plus UIImagePickerController behind a seam

**Context:** M3 needs camera capture and library import on the iOS 16 floor, no third-party deps, testable code despite the simulator having no camera.

**Decision:** Library import uses PhotosUI PhotosPicker (out of process, no photo library permission, limited access becomes moot). Camera capture uses UIImagePickerController(sourceType: .camera) wrapped by a CameraCapturing protocol seam. Ingest bakes EXIF orientation to pixels up via ImageIO thumbnails (2048 px working copy, 256 px thumb, JPEG); originals are written per retention and discarded at tagging save when set to discard. Info.plist gains NSCameraUsageDescription only. A DEVELOPMENT-only synthetic capture feeds the identical ingest pipeline for XCUITest.

**Rationale:** PhotosPicker removes the permission surface and is fully exercisable in the simulator; UIImagePickerController is the smallest stills-only camera surface for an app that downscales immediately, and the seam contains any later swap to AVCaptureSession (for example at M6).

**Trade-offs:** The camera UI is system branded and device-tested only, and the camera original re-encode is the app's largest memory spike (about 250 MB at 48 MP; mitigated by the retention-aware path, autoreleasepool, and off-main ingest). NSPhotoLibraryUsageDescription and NSPhotoLibraryAddUsageDescription stay out until any PHPhotoLibrary use lands.

## 2026-10-20, Phase 2 (M3): canvas is UIScrollView plus CAShapeLayer, geometry pure in Domain

**Context:** US-18 requires at least 55 fps pan/zoom with 100 holds on a 2048 px image and at most 3 px tap placement error at 1x on iPhone 11 class hardware. The frozen spec has no src/ui/canvas/coords.ts (the directory is a one-line stub), so the helpers are authored fresh.

**Decision:** TaggingCanvasView is a UIViewRepresentable hosting UIScrollView plus UIImageView plus a CAShapeLayer holds overlay, with UIKit gesture recognizers arbitrated by a delegate (single tap place or select, double tap zoom reset, hold drag wins over scroll when the touch lands on a hold). Coordinate helpers (fitContentBox, normToScreen, screenToScreen inverse, hitTest) are pure functions in CyberSendDomain (ios/Sources/Domain/Canvas/CanvasGeometry.swift) with golden vector tests. Roles render by shape and color plus letter (square orange, circle sky blue, triangle bluish green); a VoiceOver holds list gives full editing.

**Rationale:** UIScrollView zoom and pan are GPU composited and keep gesture deltas out of ObservableObject state, while CAShapeLayer composites hundreds of vector shapes cheaply; SwiftUI Canvas plus SwiftUI gestures would re-render per frame through main-actor store updates. Pure geometry is unit tested on macOS and pins the normalized contract that M5 detector output maps through (letterboxToSourceBox then divide by source width and height).

**Trade-offs:** UIKit hosting costs a representable sync layer and explicit gesture arbitration code. Metal was rejected as overkill for vector overlays. Tap accuracy is guaranteed by exact inverse math plus round-trip tests asserting sub-pixel error instead of by SwiftUI hit testing.

## 2026-10-20, Phase 2 (M3): climb_holds join table via Migration 002, export payload version 2

**Context:** US-20 requires holds shareable across climbs with optional beta sequence and unlinking that preserves holds and attempts, while docs/schema.sql keys holds by climb_id and the .cybersend payload is a frozen interface with pinned golden fixtures.

**Decision:** Migration 002 adds climb_holds (climb_id, hold_id, sequence, primary key over both, foreign keys CASCADE both ways, index on hold_id) backfilled from holds.climb_id with sequence = ordinal, and adds photos.original_uri. holds.climb_id stays as the origin climb (photo and lifecycle association), a documented deviation from the requirements section 2 photo_id anchor. The export payload becomes schema_version 2 (climb_holds table, photos.original_uri column) with a registered PayloadMigration from 1 that synthesizes climb_holds rows; legacy TypeScript shape imports synthesize them as well. Unlinking deletes join rows only; fall_on_hold validation becomes climb_holds membership; climb delete is blocked when owned holds are shared or attempt-referenced.

**Rationale:** Requirements win where contested (the M0 schema reconciliation precedent), and only a join table satisfies US-20.3 and US-20.4 (with holds.climb_id alone, unlinking is a hold delete that nulls attempts.fall_on_hold_id). Additive tables plus backward-compatible import is the designed evolution path of the versioned payload, so the change needs no separate byte-compat project: v1 payloads stay byte identical and data_native_golden.json becomes a pinned v1 import fixture.

**Trade-offs:** New exports no longer match the frozen TypeScript payload shape (the TS tree is a behavioral spec, not a shipping consumer; iOS only forever), and every round trip carries one more table. holds.climb_id and climb_holds can drift if writes bypass the repository, so all membership writes go through HoldRepository link and unlink APIs only.

## 2026-10-21, M4: theme is a dark first Dracula palette with measured tokens

**Context:** The theme was 21 lines of pure system semantic colors (systemGroupedBackground, label, secondaryLabel) with light and dark both following the OS. The product direction is now a cyberpunk palette in the Dracula family with dark as the default, applied across 49 view files.

**Decision:** Theme becomes an explicit token set resolved per appearance through a dynamic UIColor closure, so views keep reading Theme.x and follow preferredColorScheme with no environment plumbing. Dark surfaces are Dracula carried on a deeper base (page 1B1B26, card 282A36, hairline 44475A) so cards separate by edge rather than shadow. Alucard supplies the light palette rather than a neon-on-white remix. The accent splits into two tokens: accent (BD93F9) for icons and large glyphs, accentSolid (7A5CD6) for filled surfaces that carry a white label. SettingsStore resolves an unset ui.appearance to .dark. List based screens (Settings, Sessions history, Feature flags) hide the system grouped background through one themedPageBackground modifier.

**Rationale:** A single dynamic closure per token keeps the change surface at seven tokens instead of rewriting every view, and it preserves the appearance override that already persists under ui.appearance. The accent split exists because white on BD93F9 measures 2.4:1, which fails WCAG AA, while white on 7A5CD6 measures 4.9:1. Secondary text uses 9AA5CE instead of Dracula's comment color 6272A4, which measures about 3.0:1 on 282A36 and was previously carrying a large share of caption text.

**Trade-offs:** Six hex pairs must now be maintained by hand instead of inheriting OS colors, and the canvas overlays (hold roles, fall markers) keep their fixed content colors because they are drawn on photos, not on theme surfaces. Dark is a preference default, not a lock: users who already persisted .system or .light keep their choice, and the Settings picker still offers all three.

## 2026-10-21, M4: per attempt RPE and the retirement of the project outcome

**Context:** The session editor needs effort per climb, not only a session total, and the product decision for the UI overhaul was to remove the Project outcome entirely (Flash, Send, Fail only). Both changes touch the attempts table: outcome carries a CHECK constraint listing the allowed values, and rpe is a new column.

**Decision:** One migration, Migration 003, rebuilds attempts in a single transaction and carries both changes. rpe is INTEGER, nullable, with a CHECK of 1 to 10 matching sessions.rpe, validated in the attempt repository through the existing validateRPE so write paths surface a domain message rather than a constraint error. The outcome CHECK becomes flash, send, fail, and existing project rows are rewritten to fail during the copy. The export payload moves to schema_version 3: attempts gains rpe, nativeV2TableSpec pins the M3 shape, migrateV2PayloadToV3 stamps rpe null and rewrites project to fail, and the parser tries the version 3 shape first with a fallback to the version 2 shape. CSV attempts export gains a trailing rpe column.

**Rationale:** SQLite cannot alter a CHECK constraint in place, so a table rebuild was unavoidable; doing both changes in one rebuild means one copy of the largest table and one atomic step. Rewriting project to fail inside the migration (and again in the payload migration) guarantees no row is lost and no row can violate the narrowed CHECK, including backups restored through the payload path. The parser fallback keeps a version 3 column set stamped with an older version number importable, which the migration chain already treats as idempotent.

**Trade-offs:** The project outcome disappears from history, so any climb that was "in progress" now reads as fails. The rebuild copies every attempt row once, which is a one time cost proportional to history size but bounded by the existing 10k attempt budget. A version 2 backup keeps its project rows only as fails; nothing reconstructs the old label.

## 2026-10-21, UI overhaul: climbs.notes for problem details

**Context:** The Problems catalog needs a details field per problem (beta, style, what to remember) alongside name, grade scheme, level, angle, and photo. The frozen TypeScript schema had no such column, and the native track is now the active one.

**Decision:** Migration 004 appends a nullable `climbs.notes` text column with `ALTER TABLE ADD COLUMN`. The domain model, `CreateClimbInput`, and `UpdateClimbPatch` carry the field; the repository trims it and stores whitespace only input as nil, on create and on set. The export payload moves to schema_version 4 with `nativeV3TableSpec` (current minus `climbs.notes`), `nativeV2TableSpec` composed on it (also minus `attempts.rpe`), `migrateV3PayloadToV4`, and a parser that tries the current spec, then v3, then v2. The climbs CSV gains a trailing `notes` column.

**Rationale:** A nullable append needs no table rebuild, so the migration is one statement and existing climbs keep their rows untouched. Compositional versioned specs keep the number of pinned shapes linear rather than combinatorial: each version is the current spec minus the columns introduced after it. The ordered parser fallback covers genuine old backups and newer column sets stamped with an older version, and it still rejects any table that matches none of the shapes.

**Trade-offs:** The export payload version and its golden fixture move again, which means one more fixture in the tree (v2, v3, and v4 all remain as import inputs). Problem details are plain text only, with no rich text or per attempt notes linkage beyond the existing attempt notes.

## 2026-10-21, UI overhaul: the Problems catalog is a fifth tab over climbs

**Context:** The app needed a place to browse, add, and archive problems with their full per problem history. The domain entity already exists as `Climb` (the frozen TypeScript spec named it that), and the quick log needs the same rows listed compactly.

**Decision:** Problems is a fifth tab (`AppTab.problems`, second position) rendering `ProblemsCatalogView` over the selected gym's climbs. A problem is never a second entity: the catalog, detail screen, create form, and edit form all read and write `climbs` rows through `ClimbRepository`. Creating and editing reuse `ClimbEditorView` with a `noun` parameter ("problem" from the catalog, "climb" from the Logbook stack), so there is one editor and one validation path. The detail screen adds what the catalog needs beyond the editor: photo hero, grade badge, angle and color, details text, and the complete attempt history newest first, plus archive and unarchive. Archiving is the only removal action on the detail screen; delete stays in the editor and remains blocked while attempts exist.

**Rationale:** One entity keeps quick log, session editor, catalog, stats, and exports consistent: a problem added in the catalog is immediately quick loggable, and an attempt logged in a session shows up in the catalog history with no synchronization step. Reusing the editor avoids a second grade or photo code path. Newest first history matches how climbers read a project log.

**Trade-offs:** The catalog and the quick log can show different sets (the catalog includes inactive rows and can include archived ones; the quick log excludes both), which is intentional but means the word "problem" and "climb" refer to the same row in different screens. The list computes one attempts query per problem, which is fine at personal scale and avoids a bespoke aggregate query.

## 2026-10-21, UI overhaul: the logbook home is four blocks

**Context:** The home screen carried the gym chip strip plus a quick log climb list whose rows pushed the climb editor. That made the home a management screen with no sense of history, and the Problems tab now owns climb management.

**Decision:** The home is the session card, a consistency heatmap, the last three sessions, and the last three climbs. The heatmap is 20 weeks of local days ending on the current week, one filled cell per session start, with future days in the current week left empty; the window is fixed at 20 so the cells stay 12 pt inside the card on the smallest supported phone. Recent climbs means most recently attempted, not most recently created: a new `AttemptRepository.listRecent(limit:)` returns attempts newest first, and `HomeOverviewStore` keeps the first occurrence of each climb so a problem tried twice does not take two slots. The gym choice moved into the session card as a menu because only starting a session needs it.

**Rationale:** Consistency is the thing a tracker should show first, and a calendar grid reads faster than a list of dates. Reading recent climbs from attempts, rather than adding a last-touched column to climbs, keeps the schema untouched and makes the row order match what the climber just did. Removing the quick log list from the home removed a second climb entry point, which is the point of the Problems tab.

**Trade-offs:** The home no longer offers one tap to a climb editor; that path is now Problems, then the problem. The heatmap only counts session starts, not attempts or duration, and it does not label months, so a long streak has to be inferred from the grid position. The four blocks cost one snapshot of up to 500 session summaries plus recent attempts on every appearance; fine at personal scale, and the store is the single place to add caching if it ever is not.

## 2026-10-21, UI overhaul: the session screen adds and edits problems inline

**Context:** Logging an attempt used to require the climb to exist already, so a climber who walked up to an unlisted problem had to leave the session, go to another tab, create the climb, come back, and reopen the session. The climb editor is also where the wall photo is added, and a new climb had no photo section until it existed.

**Decision:** The session screen presents `ClimbEditorView` in a sheet for `New problem` and `Edit problem`. The create path passes the session's gym as a `gymId` override, so an inline add lands in the gym the climber is in rather than the persisted home selection. The editor takes `onSaved`, and the session refreshes and selects the saved climb, so the next outcome tap logs against it. With `keepsOpenAfterCreate` the sheet stays open after a create, reloads the row it just wrote, and therefore exposes the photo and holds sections immediately. The sheet carries a `Close` toolbar button because a sheet has no back button.

**Rationale:** One editor, one validation path, and one photo pipeline. Staying open after create turns the common "add it, shoot the wall, log the send" sequence into one uninterrupted sheet. Selecting the saved climb removes a step that used to cost a dropdown open plus a pick.

**Trade-offs:** `ClimbEditorStore.isNew` is now mutable state rather than a constant, which is a small loss of simplicity for a real flow win. The sheet keeps a second copy of the editor in memory while the session screen is behind it. Inline adds only create problems in the session's gym, so moving a problem to another gym still goes through the catalog.

## 2026-10-21, UI overhaul: session media (retroactive photos and clips)

**Context:** A session could not hold a photo or a video. The photos and videos tables already carry a nullable session_id, the videos table, model, repository, and export spec shipped with the M3 schema, and the backup writer already packs video files whose retention class is keep. What was missing was the ingest path, the storage directory, and a screen.

**Decision:** Every session screen (open and closed) renders a session media block. Photos import from the library through the existing ingest pipeline via `PhotoStore.addSessionPhoto`, which is the same decode and re-encode as a climb photo but with a nil climb and no one-photo-per-owner rule, because a session holds a gallery. Videos import from the library as bytes, are written untouched under `videos/`, and a `videos` row records the session link, dimensions, and duration read from the file with AVFoundation. Imported clips use retention class keep, which is what makes the existing backup writer include them. Playback is AVKit `VideoPlayer` in a sheet: no trimming, no frame export, no pose. On a live session the quick log controls stay first and media sits under the attempt list; on a closed session the gallery leads.

**Rationale:** Reusing the photo pipeline keeps one decode, orientation, and EXIF path. Copying video bytes instead of transcoding keeps import fast, keeps the original the climber shot, and keeps the app out of video editing entirely. The retention class decision means clips survive backup and restore without touching the export schema or the media manifest.

**Trade-offs:** A video import loads the clip into memory to hand it to storage, which is fine for bouldering length clips and would need a streaming transfer for long footage. MediaSweep reconciles photo files only, so a clip whose file disappears is reported by the player as unavailable rather than swept at launch. There is no video thumbnail, so the row is a play tile with a duration; a generated poster frame is future work.

## 2026-10-21, UI overhaul: climb categories are a fixed enum in one nullable column

**Context:** The problem editor and the catalog need to describe what kind of climb a problem is (slab, dyno, crimpy, overhang, campus, comp, and so on), separately from how hard it is. Nothing in the schema carried that, and filtering the catalog by category means the value has to be stable enough to match.

**Decision:** A fixed `ClimbCategory` enum carries the allowed tags with canonical raw tokens and display titles. A climb holds a set of them, stored comma separated in `climbs.categories` (Migration 005, nullable text) in declaration order. `encodeClimbCategories` returns nil for an empty set, `parseClimbCategories` ignores unknown tokens, blanks, case differences, and duplicates, and `orderedClimbCategories` is the single normalizer used by the repository so the in-memory value and the stored bytes agree. The export payload moves to version 5: the current spec gains the column, `nativeV4TableSpec` is the spec without it, `migrateV4PayloadToV5` stamps it null, and the parser lookup chain becomes current, v4, v3, v2. The climbs CSV gains a trailing `categories` column.

**Rationale:** Categories are descriptive only: no domain rule, no ranking, no grade interaction depends on them. A join table would mean a new export table, dump ordering, restore wiring, and CSV surface for something that is read at personal scale and filtered in memory, while a column matches how `notes` was added and keeps the versioned payload practice that already covers three earlier column additions. Declaration order keeps backups byte stable and makes the column readable by eye.

**Trade-offs:** Filtering by category happens in memory rather than in SQL, which is fine for one climber's catalog and would need an index or a join table at a much larger scale. Renaming a token later needs a data migration. Unknown tokens are silently dropped rather than reported, so a category added by a newer build disappears quietly on import here instead of warning.

## 2026-10-21, UI overhaul: the editor is one form with details, categories, and a single tagging path

**Context:** The climb editor had grown by addition: Name and a Grade card, then a Details card with free text angle and color and a notes field, then a save button, then photo and holds cards, then a manage card with an attempt count. Two "Tag holds" links existed (one under the photo, one in the holds card), the holds card repeated the count the row detail showed, and the gym was fixed to the logbook selection even though the session passes a gym override. The problem detail screen carried a tagging link too, so the read only screen could write holds.

**Decision:** One form, in the order Name, Details (gym, grade scheme, level, wall angle, colour circuit), Notes, Climb category, Photo, Holds, Manage. The gym is a picker: a create uses the picked gym (falling back to the session or logbook selection), and an edit can move the problem, which is why `Climb.gymId` became a variable and `UpdateClimbPatch` gained a validated `gymId`. Categories are a toggle grid over the fixed `ClimbCategory` list. Tagging exists only as the Holds row; the duplicate link under the photo was removed and the holds card no longer repeats a count (the row detail is the summary). Manage lost the attempt count because the problem history owns it, and Archive and Delete sit side by side. The detail screen shows photo, gym, name with grade, category chips, a read only View hold stats sheet, notes, history, and edit plus archive: tagging is reachable only through Edit problem. A photo picked while the problem is still unsaved saves the problem first, then ingests, and continues in edit mode.

**Rationale:** The editor is used at the wall with one hand, so the fields belong in the order a climber thinks about the problem (what it is, where it is, what it feels like) rather than in the order the schema grew. One tagging path removes the question of which link to use and keeps the write surface in the editor. The read only detail keeps the catalog honest: tapping a problem to look at it cannot accidentally change its holds. The gym picker retires the old "move a problem through the catalog" workaround.

**Trade-offs:** A create screen now carries photo and holds sections that mostly say "save first", which is two cards of noise for someone who only wants to type a name. The auto-create on photo ingest writes an untitled problem if the climber shoots the wall before naming it; deleting it afterwards is the recovery. Moving a problem to another gym keeps its old walls and holds, which are gym specific, so the editor does not clear them automatically.

## 2026-10-21, UI overhaul: session climb membership is derived from attempts plus an in-memory add list

**Context:** The open session screen had one selected climb behind a dropdown. The ask was a workout style list where each climb added to the session is a row, with Add Climb, Edit Problem, and New Problem side by side, and attempts editable during the session. A persisted membership list would mean a new table, an export table, dump ordering, restore wiring, and a payload version for something the session can already infer.

**Decision:** SessionDetailStore keeps an ordered `addedClimbIds` list. On every reload it drops ids the gym no longer resolves, appends every climb that has an attempt in the session, and keeps the selection inside the list (an existing session opens on its first climb). Add Climb appends and targets a climb; a climb with no attempts can be removed, one with attempts cannot because attempts are the stronger fact. The list survives refreshes on the screen and is rebuilt from attempts when the session is reopened. The Attempts section stays flat with the climb name first, then the result, effort, and fall hold, and each row opens the existing edit sheet while the session is open.

**Rationale:** Attempts are already the durable record of what a session touched, so deriving membership from them needs no schema change, no migration, no export surface, and cannot drift from the attempts it describes. The in-memory list only covers the gap between adding a climb and trying it, which is exactly the window where nothing is written yet. Reusing the edit sheet for open sessions is one code path for both states.

**Trade-offs:** A climb added and never tried disappears when the screen is left or the app restarts, which is arguably correct but can surprise. The list is per screen, so two devices or two windows would not share it. Removing a climb with attempts is refused silently in the store (the button is hidden), which is a small hidden rule.

## 2026-10-21, UI overhaul: the catalog spans gyms and filters in memory

**Context:** The Problems tab followed the logbook's selected gym. Once rows show their gym and the catalog needs a gym filter, following a hidden selection at the same time is confusing, and a filter that only ever has one value is not a filter.

**Decision:** The catalog loads every climb (archived included only when the toggle is on) once, resolves gym names and grades in the store, and filters in memory by gym, level (scheme plus level id, so two schemes labelled V4 stay distinct), category, and climb status (sent, flash, ongoing). Level options are ordered by scheme and level rank rather than alphabetically, so V2 sorts before V10. Filters that no longer match after a reload are cleared rather than leaving an empty list. The empty state distinguishes "no problems yet" from "no problems match" and offers Clear filters.

**Rationale:** Personal catalogs are small, and one load plus in-memory filtering keeps the SQL surface unchanged (US-13) while making every filter instant. Gym and level pairs are the identity of a row, so the filters compare those rather than display strings. Status means what the badges mean: sent covers a plain send, flash covers a flash, and ongoing means neither yet.

**Trade-offs:** Every reload reads every climb and one attempt query per climb for the summary, which is fine at hundreds of problems and would need an aggregate query much later. The rows are all in memory, so a very large imported catalog costs memory rather than paging. Status is not a stored field, so "ongoing" is computed from attempts each time.

## 2026-10-21, Visual pass: themed fields, outcome colours, wrapped filters, and the app icon

**Context:** A simulator screenshot pass over the overhauled screens found a handful of
things that read as defects. Text fields used the system rounded border, which fills with
the page background, so every field on a dark card was a black rectangle. The three outcome
buttons were the same accent purple, three identical primary actions one thumb slip apart.
The fourth catalog filter (status) sat off screen inside a horizontal scroller, so the most
useful filter was invisible. The photo empty state said "Add wall photo" twice: once in the
empty state card and once in a full width button below it. The app icon was still the old
orange petal mark.

**Decision:** Four UI changes and one asset change, all mechanical:

- `themedField()` (App/UI/Theme/Theme.swift) replaces `.textFieldStyle(.roundedBorder)`
  everywhere: raised surface fill, card border, 10 pt radius, primary text.
- Outcome buttons are soft tinted buttons in the outcome colour (flash info cyan, send
  success green, fail danger red) with a matching border and label. The colour is defined
  once as `AttemptOutcome.themeColor` and reused by the problem history badges. Disabled
  buttons use a 6 percent tint and tertiary text, and the Edit Problem action in the open
  session draws its own disabled colour for the same reason.
- The catalog filter bar uses a small `FlowLayout` instead of a horizontal ScrollView, so
  gym, level, category, and status all stay visible.
- The photo empty state is one tappable card; the duplicate button is gone.
- The app icon is the supplied climbing mark rendered white on a purple gradient
  (#8E6BE0 to #684AC6, the accentSolid family), 1024 px, no alpha, single size asset.

**Rationale:** A field has to look like a field, not a hole in the card. Outcome colour is
already the language of the attempt badges, so colouring the buttons makes the action and
its record match and removes the three identical primary actions. A filter that is off
screen is not a filter, and wrapping costs one row of vertical space. One affordance per
action, and an icon that uses the app's purple rather than an unrelated orange.

**Trade-offs:** The themed field drops the system focus treatment, so the cursor and the
keyboard are the only focus cues; a focus border would need its own state plumbing. Tinted
outcome buttons are less loud than the filled accent button they replaced, which is the
point, but they read as secondary next to Save changes. The wrapping filter bar takes a
second row on a phone. The icon's white glyph sits between 3.9:1 and 6:1 against the
gradient, which is fine for a non text mark but would be too low for body text.

## 2026-10-21, Phase 4: Harness gains per-model preprocess and YOLOX postprocess

**Context:** The D1 phase produced two Apache-2.0 exports with incompatible contracts. RF-DETR takes ImageNet-normalized RGB and emits normalized cxcywh plus per-class logits with no NMS. YOLOX takes raw 0..255 RGB and emits cxcywh pixels with objectness and class scores, also without NMS. The harness had exactly one hard-coded contract, so only RF-DETR could be scored.

**Decision:** The Detector interface declares a `preprocess` mode ("imagenet" or "raw"); evaluate.ts encodes the tensor from that declaration. YOLOX postprocess lives in a new `decode_yolox.ts` (clipped xyxy, score = objectness times best class, class-agnostic greedy NMS at IoU 0.65 over anchors scoring at least 0.01), mirroring the training-side COCO evaluation. `--model-kind` defaults to auto and infers the kind from output names, refusing to guess on anything unknown.

**Rationale:** Two models with different contracts were always going to need this, and putting the contract on the detector keeps one source of truth instead of a flag that can silently disagree with the model. NMS at 0.65 with a 0.01 floor is the convention the YOLOX validation numbers were produced under, so harness numbers are comparable to the training log. Verifying the cxcywh reading against ground truth first (0.79 mean best IoU as cxcywh versus 0.00 as xyxy) avoided baking a convention error into the metric.

**Trade-offs:** The harness now carries model-specific postprocess, which is scope it did not have, and the YOLOX decode path is only exercised against the real export (unit tests cover the pure functions, not the graph). The 0.01 pre-NMS floor means the YOLOX mAP is not directly comparable to RF-DETR's mAP at a 1e-4 floor, a gap that matters little in practice because the operating point is 0.5. Result on val: YOLOX fails the Phase 4 recall gate at every threshold, so the single gated test run goes to RF-DETR.

## 2026-10-21, Phase 4: D1 accuracy winner is not shippable, decision pending

**Context:** D1 trained two Apache-2.0 candidates and spent the single frozen test run on RF-DETR-Nano. RF-DETR passes the three accuracy thresholds (precision 0.9509, recall 0.8788, mAP@0.5 0.9130) and the count-error limit (1.0), but produces 1.8832 false positives per image against a 0.5 budget, and its 28.9M parameters put an int8 build at roughly 29 MB against a 15 MB budget. YOLOX-Nano meets size (about 1 MB int8) and mAP, but cannot reach 0.80 recall at any threshold (0.80 recall costs precision down to 0.7168).

**Decision:** Treat Phase 4 as accuracy-decided but shipment-blocked. RF-DETR is the model of record for evaluation and the target of the Core ML feasibility check; it is not a shippable model. No gate threshold is being revised now. The decision between rescaling or retraining YOLOX and revising a budget (with recorded justification) waits until the Core ML feasibility result is in, because a conversion failure removes RF-DETR from consideration entirely and the two branches lead to different work.

**Rationale:** The false positive rate is the real product problem: 1.88 wrong boxes per photo at the operating point would make the prefill feature annoying enough that users turn it off, which defeats the tagging accelerator. Size is a harder constraint than it looks because Core ML weight compression does not beat one byte per parameter. Proceeding with conversion first costs hours and settles whether the accuracy winner is even deployable, which determines what the next training iteration must optimize.

**Trade-offs:** Delaying the YOLOX retrain risks spending device and conversion effort on a model that may be replaced anyway. Choosing RF-DETR now would mean shipping a feature that fails two of its own quality budgets, so that is not available. The false positive gap may improve with a higher operating threshold on val, but that trades directly against the recall floor, so it is not a free fix.

## 2026-10-21, Phase 4: Core ML conversion is feasible, the budgets are not

**Context:** After D1 left Phase 4 accuracy-decided but shipment-blocked (false positives 1.8832 per image versus 0.5, int8 size about 29 MB versus 15 MB), the open question was whether the accuracy winner could even be deployed: RF-DETR carries two GridSample nodes in decoder cross attention, historically the op class that blocks Apple backends. rfdetr 1.11.2 ships a Core ML exporter that rewrites deformable attention into a rank 5 path, and coremltools 9.0 is available in the training environment.

**Decision:** Record Core ML conversion as technically feasible and not a shipment path. The float32 package passes decision-space parity against ONNX (8.31e-4 hold score, 8.79e-7 box) and runs warm at 41 to 50 ms on the M5 with all compute units. Weight compression is not adopted: float16 (51.6 MB), int8 (26 MB), and int4 (13 MB) all fail the parity gate, with int4 returning non-finite boxes. Keep the 15 MB budget as written. Keep ONNX canonical and treat the Core ML package as a conversion artifact until a model is shippable.

**Rationale:** Conversion risk is now a measured fact rather than an assumption, and it points the same way as the earlier gate result. The only parity-clean package is 104 MB, so a Core ML success does not make RF-DETR deployable; adopting a compressed package would trade a hard size rule for an unmeasured accuracy loss on a model that already misses the false positive budget. Recording the numbers lets the next decision be made on evidence: int8 at 26 MB is close enough to 30 MB that a validated accuracy number could justify a revised budget, while int4 at 13 MB is not a candidate at all.

**Trade-offs:** Leaving the budget untouched blocks the phase for now, and measuring int8 val accuracy would cost a Core ML evaluation path in the harness (the current harness is ONNX only) before it can inform anything. The alternative, relaxing size on parity evidence alone, would ship a deployment copy whose hold scores drift by up to 0.45 on a sensitive image, which is worse than waiting. The Mac latency numbers are a proxy only: A13 cold load and thermal behavior remain unmeasured, so the 2 s cold-load criterion is still open even for the parity-clean package.

## 2026-10-21, Phase 4: no operating threshold satisfies the D1 acceptance region

**Context:** The frozen test result was recorded at confidence 0.5 with false positives 1.8832 per image, which reads as 3.8x over the 0.5 budget. That number was measured at the operating point chosen to protect recall, not at a point chosen to satisfy the false positive limit. Measuring the val curve settles whether a better threshold exists.

**Decision:** Treat the Phase 4 accuracy gate as structurally unmet for D1 and target false positives in the next training iteration. Do not re-threshold D1 and do not spend another test run on it. The 0.5 operating point stays the reference for the recorded test numbers.

**Rationale:** On val, recall stays at or above 0.80 down to about confidence 0.765, where false positives are about 0.56 per image and median count error is about 3. At 0.80 false positives pass (0.4213) but recall falls to 0.7603 and count error rises to 4. Count error only reaches the 1.0 limit at or below 0.60, where false positives are 1.35. The three limits conflict along the whole curve, so the gap is a model quality gap (spurious detections at usable recall), not a threshold selection error. The gap at the recall floor is small enough that a targeted retrain (hard negatives, harder background variety, more wall coverage) is a plausible fix, which is different from needing a different architecture.

**Trade-offs:** Retraining costs another training cycle and the frozen test run can only be opened once more if the budget policy is extended or the phase is re-scoped, so the next model must be judged on val and only spent on the test split once it clears every limit there. Treating 1.8832 as the headline number overstates the real gap; treating the 0.56 point as acceptable would quietly break the recall floor and the count error limit, so neither shortcut is taken.

## 2026-10-21, Phase 4: scaling YOLOX chosen over revising the budgets

**Context:** D1 left no shippable model. RF-DETR-Nano clears the accuracy thresholds but misses the false positive budget at the recall floor (about 0.56 versus 0.5) and cannot reach 15 MB at int8 by parameter count, with compression breaking parity. YOLOX-Nano fits size with room to spare but reaches precision 0.7168 when recall hits 0.80. The user chose between scaling YOLOX, revising the budgets, and pausing.

**Decision:** Scale YOLOX. Train YOLOX-S (depth 0.33, width 0.50, 8.94M parameters) at 640 on the same dataset, schedule, and seed as the Nano run, initialized from the official Apache-2.0 COCO checkpoint. Keep the 15 MB budget and the false positive budget as written. Judge the result on val, not on the frozen test split.

**Rationale:** Size headroom is the one thing YOLOX has and RF-DETR does not: about 9 MB at int8 against a 15 MB limit, on a Conv/Sigmoid-only graph with no attention, no GridSample, and no compression needed to fit. The accuracy gap is a precision gap at fixed recall, and the likely cause is capacity: RF-DETR reaches 0.949 precision at 0.889 recall on the same 640 px contract, so the information is present in the input and a 0.9M parameter model is not extracting it. S is the smallest capacity step that still fits the budget, and it keeps the deployment contract identical, so the harness and app path need no change.

**Trade-offs:** The training set is 1804 images, so a 9M parameter model can overfit, which is why the augmentation schedule and the fresh seed comparison matter. S is also about 25x the FLOPs of Nano, so epochs cost more; the isolated timing predicts about 1.7 h and the recorded Nano run predicts about 5.5 h, so the first epoch is checked before committing. If S still misses precision at the recall floor, the next options are Tiny at higher input resolution (which changes the shared 640 contract) or revising the budgets with the measured curve as justification, in that order.

## 2026-10-21, Phase 5: Vision body pose chosen, Pose v1 scope defined

**Context:** The 2026-10-19 native migration record listed Vision body pose as a spike candidate benchmarked against TFLite MoveNet, and the earlier React Native record named MoveNet as the pose plan. Phase 4 remains blocked: no hold detector passes its gates (RF-DETR misses the false positive budget at the recall floor and cannot reach 15 MB, YOLOX-Nano misses recall), so a video feature that depends on hold detection cannot ship. The user approved a Pose v1 plan on 2026-10-21 after an interview covering the job to be done, sequencing, camera setups, capture path, validation corpus, product surface, and metric basis.

**Decision:** Seven parts. (1) Phase 5 pose uses `VNDetectHumanBodyPoseRequest` (2D, 19 named joints) with no bundled model, no Core ML conversion, no quantization, and no parity gate; this supersedes the MoveNet and TFLite pose candidate. (2) Pose v1 ships with no hold dependency: hold contact, hold dwell, and fall on hold are Pose v2, gated on either a shippable Phase 4 model or a photo to video homography. (3) Metrics are reported in the image plane normalized by body height and labelled relative, with no absolute velocity, force, or metre claims; the vertical progress signal is the shoulder and hip midpoint, called body centroid and never centre of mass. (4) Comparison is metric comparison gated on camera stability class (static, near static, handheld), not spatial overlay, because handheld clips have no shared frame. (5) Video retention defaults to keep, superseding the delete after extraction default in US-36, because the review surface depends on the video existing. (6) Analysis results are stored as one `video_analyses` row plus a packed Float16 track blob plus `analysis_events` rows; the `pose_keypoints` row per frame design is deprecated, stops being written, and keeps its table and export spec for compatibility. (7) Every analysis records `algorithm_version` and `vision_revision` so threshold changes and OS level pose model changes invalidate analyses explicitly instead of silently mixing incomparable numbers.

**Rationale:** Vision removes the whole model management surface: nothing to convert, quantize, bundle, license, or parity test, and the request is available from iOS 14 so it fits the iOS 16 floor without weakening it. It also decouples the feature from the one milestone that is currently failing, which means video analysis can ship value while hold detection is still being retrained. The scope decisions follow the evidence we already hold: Google's 2021 benchmark puts Vision 2D pose well below BlazePose on dance and yoga, and there is no climbing specific benchmark, so wrist accuracy is the least defensible signal and contact detection is the correct thing to defer rather than the thing to build first. Body height normalization is the only basis that survives an unknown camera distance without calibration, and camera class gating is what keeps comparison honest when the phone was handheld.

**Trade-offs:** Vision accuracy is an unproven quantity on climbing footage, so P0 exists to produce the answer before UI work is funded, and the plan degrades rather than collapses if it is bad: Tier C contact detection is cut, and Tier A progress and movement metrics survive. Body scale normalization degrades under foreshortening and inversion, which is a real ceiling on the approach and not a bug to fix. Keeping clips by default costs storage, mitigated by the existing 1 GB warning and 2 GB prompt plus per clip delete. The requirements change also weakens US-39 relative to its original wording, which promised side by side comparison; that is recorded here rather than left as silent under-delivery.

**Deferred:** 3D pose (`VNDetectHumanBodyPose3DRequest`, iOS 17+) as a possible route to metric units, the iOS 18 holistic hands path beyond a capability tier, real-time overlay during capture, background processing queues, cross-climb comparison, and wall-plane homography. Each needs its own decision after P0 measurements.

## 2026-10-21, Pose v1: one pipeline entry point, unclassified clips count as handheld

**Context:** Extraction, Tier A metrics, and storage were three separate calls after P3, so nothing enforced the order, nothing set `videos.pose_status`, and a track that produced no metrics had no obvious home. Camera stability class is the gate that decides whether a clip may be compared, so the default when it is unknown decides a product rule, not an implementation detail.

**Decision:** `PoseAnalysisPipeline` is the only thing that writes an analysis. It runs extraction, metrics, and `saveAnalysis` inside one actor, sets `pose_status` to running, done, or failed, and converts the metric warnings into comma separated quality flags. A track that yields no metrics is still stored with `camera_class` forced to `handheld` and the flag `metrics_unavailable`.

**Rationale:** Keeping a usable track is the cheap half of the work and re-extraction is the expensive half, so discarding a track because the body could not be scaled would pay twice for the same clip. Storing it as `handheld` is the conservative default: an absent classification must not unlock metric comparison or a spatial overlay, and every other value would do exactly that. One actor also enforces the single-analysis-at-a-time thermal rule without a separate lock.

**Trade-offs:** A stored analysis with no metrics looks like a success to any caller that checks only for the row, so the review UI has to read `quality_flags` to explain an empty summary. Forcing `handheld` also loses the true camera class for a clip that could not be classified; recomputation restores it once the body scale is available.

## 2026-10-22, Phase 4: YOLOX-S closes the accuracy gap, not the false positive gap

**Context:** Scaling YOLOX was chosen after D1 so that a model could pass the accuracy thresholds and still fit the 15 MB int8 budget. YOLOX-S trained 40 epochs on the same data, schedule, and seed, initialized from the Apache-2.0 COCO checkpoint, and exported with parity intact (8.92e-6 score, 1.43e-6 box).

**Decision:** Record D1b as a partial success and not as a shippable model. YOLOX-S at about 9 MB int8 passes precision (0.9029), recall (0.8050), and mAP (0.8709) at confidence 0.40, which no D1 model did, but it misses the false positive budget by 6.7x (3.3350 versus 0.5) and the count error limit by 2x (2 versus 1). Do not spend the frozen test split on it. The next decision is explicitly open: structural false positive work on YOLOX, a targeted false positive fine-tune on RF-DETR plus a size decision, or a product-level revision of the false positive and count criteria.

**Rationale:** The scaling hypothesis was half right. Capacity did limit accuracy: recall at confidence 0.5 rose from 0.6725 to 0.7656 and mAP from 0.8101 to 0.8709, and false positives at the recall floor fell from 12.20 to 3.34 per image. But the remaining false positives are not a capacity artifact. RF-DETR sits about 6x closer to the budget at the same recall because set prediction assigns one query per hold, while YOLOX relies on NMS at IoU 0.65 and leaves near-duplicates that the metric counts. Adding capacity again would cost another training cycle for an uncertain gain on a criterion that is six times over.

**Trade-offs:** Stopping the YOLOX line here leaves the size advantage unused and keeps Phase 4 blocked, which is honest given the numbers. The alternatives each bend something: hard negatives and stricter NMS on YOLOX would need to remove about 85% of the excess false positives to reach 0.5, a targeted RF-DETR fine-tune is only 12% away but forces the size budget question (26 MB int8, parity currently failing), and revising the criteria means changing a product rule rather than meeting it, which needs the user's explicit call rather than a technical workaround.

## 2026-10-22, P4: recorder is capture only, no audio, and hands off a file

**Context:** P4 needs an in app recorder whose output the pose pipeline can read. The app already imports library video bytes into videos/ and creates a row, and the analysis pipeline (P3 bridge) needs a video row to attach to. The open questions were how much the recorder should do, whether it records audio, and how the file reaches storage.

**Decision:** Four parts. (1) The recorder records video only, with no audio input, so it never requests microphone permission. (2) Format policy is 1080p60, then 1080p30, then a 720p floor, never 4K by preference; the policy is a pure function over format descriptors. (3) The recorder stops at 90 s in the UI and the movie output stops at 95 s as a backstop. (4) The finished file is adopted by `MediaStorage.adoptVideo`, which moves it into videos/ rather than reading it into Data, and the session store creates the row with `pose_status` pending and retention keep.

**Rationale:** Audio has no use in this feature and asking for the microphone would add a permission that a climbing clip does not need. 1080p60 is the smallest format that keeps fast movement sampleable for event boundaries, while 4K only inflates stored bytes because Vision sees 720 px. Moving instead of copying matters at 1080p60: a 60 s clip is around 200 MB and a copy would double peak disk and memory pressure for no benefit. Marking the row pending, rather than done, keeps the recorder from claiming an analysis it did not run.

**Trade-offs:** No audio means a clip cannot be reviewed with the sounds of the attempt, which is a small loss for a training log and a real one for anyone who wanted the clip as a memory. The 90 s limit rejects a long bouldering session filmed in one take, which is intentional: one attempt per clip is what the metrics assume. Pending rows are inert until an analysis queue exists, so a recorded clip looks unanalysed until P5, which is honest but will read as incomplete in dogfood.

**Deferred:** US-40a item 3 also allows 1080p120 where the device supports it. The recorder records at 60 fps instead, because the analysis path strides to at most 60 Hz and the clip is kept by default, so 120 fps doubles stored bytes for no Tier A gain. Revisit if P0 shows event boundaries need finer timing than a 16.7 ms sample, which is unlikely for a fall that lasts hundreds of milliseconds.

## 2026-10-22, P5: metrics are derived on demand, analysis is a tap, and clips live under Stats

**Context:** P5 has to show what an analysis found without turning the review screen into a second source of truth. The open questions were whether to persist metrics next to the track, whether analysis should start automatically when a clip is imported or recorded, and where the clips surface belongs in a five tab app.

**Decision:** Three parts. (1) Metrics are never stored; `VideoAnalysisStore` recomputes them from the packed track through `TierAMetricsEngine.compute` on demand, while the stored record supplies the quality flags, algorithm version, and camera class. (2) Analysis runs on an explicit tap, is cancellable, and a cancelled run returns the clip to `pending`. (3) The clips surface is a pushed screen under Stats, not a sixth tab.

**Rationale:** Storing metrics would freeze the numbers at analysis time, so a threshold change would leave two kinds of clips in the app and no way to tell them apart without a migration. The track is small (about 103 KB for 900 frames) and decoding it is fast enough to run when a screen opens, so derived numbers stay current by construction. An automatic run on import would spend minutes of CPU on a clip the user may have added for playback only, and it would make the experimental flag feel like it did something the user did not ask for; a tap is also the natural place to hang cancellation. A sixth tab would collapse the tab bar into More on iPhone, and the clips list is an analysis surface, which is what Stats already is.

**Trade-offs:** Recomputing on every open costs a decode and a metrics pass per screen view, which is fine for one clip and would not be for a long list, so the clips list deliberately shows only status and never metrics. An explicit tap means a recorded clip can sit unanalysed indefinitely; the row says "Not analysed" rather than pretending. Cancellation on leaving the screen is a judgement call: work that continues invisibly after a dismissal would be worse, and the clip stays analysable.

## 2026-10-22, Phase 4: the false positive budget is not measurable on the merged public split

**Context:** After D1b, RF-DETR was chosen as the model to push on false positives because it sits about 12% over the budget at the recall floor. Before spending a training run, the operating point false positives were classified with a new harness analyzer, and the boxes were cropped and inspected against the ground truth.

**Decision:** Stop treating the false positive and count error criteria as measurable on the merged climbtag, blackcreed, and pwals split. Do not train hard negatives, do not add post-processing filters, and do not spend the frozen test split on a false positive experiment. Measure those two criteria on the Phase 0 dense own-gym eval set (docs/requirements.md US-5) once it exists. RF-DETR remains the model of record and YOLOX-S remains the size fallback, both unchanged by this entry.

**Rationale:** At confidence 0.765 on val, 335 false positives break down as 3.6% duplicates, 35.8% near misses, 14.6% loose, and 46.0% background. Cropping 24 background boxes with the ground truth overlaid showed about 20 sitting on real holds or volumes with no label, and one image (blackcreed__781) has 27 labels against 37 visually correct detections because its labels are large overlapping regions. The 10 worst images hold 23.9% of all false positives. Every deterministic fix was swept: dedupe at any IoU saves at most 3%, an area floor at 100 px2 reaches 0.48 only by dropping recall to 0.7151, and an edge filter costs recall faster than it saves false positives. The 0.5 budget cannot be reached by post-processing, and it cannot be reached by training either, because the residual is label error rather than model error.

**Trade-offs:** This leaves Phase 4 formally unshippable on its current numbers and moves the critical path to data work: 200 densely labelled own-gym photos, which is manual effort. The alternative, training hard negatives against the current labels, would measurably improve the metric while making the product worse, which is the one outcome worth ruling out explicitly. The size and parity question (26 MB int8, compressed Core ML parity failing) is independent of this and can proceed in parallel.

## 2026-10-22, P6: Tier B is pose only, and comparison refuses handheld clips

**Context:** P6 was specified as "gated comparison, Tier B metrics: dyno, cut feet, rest". Hold contact was already deferred to Pose v2, which leaves the question of what dyno, cut feet, and rest can honestly mean without hold geometry, and how two clips may be compared when they were filmed from different phones in different places.

**Decision:** Three parts. (1) All three Tier B events are pose-only proxies: a dyno is a wrist speed peak with real travel across the peak window, cut feet is both ankle offsets below the hips shrinking while the body does not rise, and a rest is a still run inside the attempt. Every surface that shows them says they are not hold contact. (2) Comparison refuses any clip classified handheld, because a handheld frame has no fixed coordinate system. Two comparable clips compare on numbers and on a progress curve resampled to attempt progress, never on pixels. (3) Hesitation maps are only carried into a comparison when both clips are stationary, and even then the model notes that a spatial read assumes the phone did not move between sessions.

**Rationale:** Without hold detection or a homography, any claim that a hand touched a hold would be a guess dressed as a measurement, and this feature is experimental enough that one overclaim would discredit the rest. The pose signals that do survive are movement shapes: hand speed and travel, ankles closing on the hips, and stillness. Comparison is the one place where the app could silently compare incomparable things, so the gate is a refusal rather than a warning: a handheld clip produces no comparison at all, and the screen explains why. Normalizing the curve to attempt progress is what makes a 20 second attempt and a 50 second attempt legible on one axis; normalizing height to body heights is what makes two climbers of different sizes comparable at all. Keeping the hesitation maps out of near-static comparisons follows from the same reasoning: a map in image coordinates only means something if the camera frame is shared.

**Trade-offs:** Refusing handheld clips will feel strict, because most clips a user records by hand will not compare, and that is the largest source of footage this feature could have. The alternative was a comparison whose numbers move when the phone moves, which is worse than no comparison. Pose-only Tier B will miss real dynos where the hand moves fast but the pose is lost to motion blur, and will fire on fast reaching that is not a dyno; the thresholds are hypotheses until the P0 corpus exists, which is why they live in one versioned struct and the algorithm version moved to 2 so older analyses are visibly missing the events. Resampling to 50 points smooths away short hesitations in the curve; the hesitation map, when both clips allow it, is the place to see those.

## 2026-10-22, Pose v1 acceptance criteria that are still open

P1 to P6 are built, tested, and behind the flag. Six acceptance criteria from US-36 to US-40 are not met yet, and they are listed here rather than left implicit.

| Criterion | Current state | Why it is open | What it would take |
|-----------|---------------|----------------|--------------------|
| US-36.1 size stored at import | Duration, width, height, and fps are stored; byte size is not | Nothing reads size yet, so it was not added to the schema | A `byte_size` column plus a migration and export field |
| US-36.3 cache warns at 1 GB, prompts at 2 GB | No cache accounting for photos or videos | The budget belongs to storage, not to pose, and applies to photos too | A directory size pass at launch and on import, a warning row in Settings, a prompt before the next import |
| US-36.4 deleting the raw clip keeps extracted metrics | Deleting a clip deletes its analysis: `video_analyses.video_id` is `ON DELETE CASCADE` | Metrics are derived from the stored track, so keeping them needs an analysis that outlives its video, which changes the schema and the screens that list clips | Migration to a nullable `video_id` with `ON DELETE SET NULL`, an analysis centric list for detached rows, export and restore coverage |
| US-37.5 pose budgets | Unmeasured | Needs the P0 corpus and a device run | Measure extraction speed, thermal state, and battery on the corpus |
| US-37.6 processing resumable | Cancellable yes; a cancelled run restarts from zero. The frame reader accepts `startAfterMs` but nothing persists a partial track | Persisting partial tracks needs a place to put them that export and restore understand | Persist the partial track and a resume marker periodically, then resume on relaunch |
| US-38.4 error budgets | Unmeasured | Same as US-37.5 | Compare metrics against the corpus ground truth |
| US-39.1 fall relabel path | Falls are detected and stored; there is no UI to relabel one | It needs an event editing surface and a stored override, which is new schema and UI | An event editor on the review screen plus a `user_label` column |
| US-40.3 crash or budget breach auto-disables | The crash half is implemented (marker at launch turns the flag off, stuck rows go back to pending, Settings offers a one-tap re-enable). The budget breach half is not implemented | There is no measured budget to breach until US-37.5 exists | Measure the budgets on the P0 corpus, then add the breach check beside the crash check |

None of these block dogfooding the pipeline. They do mean the feature cannot be called complete against the requirements, only complete as an experimental v1 with a known list.

## 2026-10-22, US-40.3: a leftover run marker turns the pose flag off at launch

**Context:** `ai_pose_analysis` is experimental, and an analysis runs in the foreground with no way to observe a crash after the fact. A crash loop in an experimental feature is the worst failure mode available: the user taps the only clip they have, the app dies, and the flag stays on.

**Decision:** Three parts. (1) A marker is written to UserDefaults when a run starts and cleared on every exit path, including cancellation. (2) Any marker present at launch is treated as an interrupted run, with no age threshold, because a process that has only just started cannot have an analysis in flight. The launch path turns the flag off, resets rows stuck on `running` to `pending`, and persists a notice. (3) Settings keeps the Experimental section visible while the notice is set, so one tap turns the feature back on and clears the notice.

**Rationale:** The marker is a liveness fact, not a health metric: at launch it is either absent or it means the previous process died mid run. Skipping the age threshold removes a tuning parameter that would only ever produce false negatives. Resetting `pose_status` matters as much as the flag, because a row stuck on running would otherwise present a clip as permanently analysing. Keeping the re-enable path in Settings is what makes an automatic disable acceptable rather than a dead end.

**Trade-offs:** A force quit during analysis is indistinguishable from a crash and will disable the feature, which is a false positive by definition. The alternative is guessing at intent, and the notice plus one-tap re-enable keeps the cost low. The marker lives in UserDefaults rather than the settings table, so it does not travel with a backup, which is correct: it describes this process, not the user's preferences. The budget breach half of US-40.3 is not implemented, because there is no measured budget to breach until the P0 corpus exists.

## 2026-10-22, Phase 4: the 15 MB budget is unreachable for RF-DETR at the iOS16 floor

**Context:** The 2026-10-21 Core ML entry concluded that float16, int8, and int4 packages all fail parity. That conclusion was re-examined with a decision-level gate and a full val evaluation through the Core ML runtime.

**Decision:** Adopt the 26.4 MB int8 k-means per-tensor package as the reference compressed RF-DETR artifact, and record the 15 MB bundled budget as unmet at the iOS16 floor rather than as a tuning problem. The per-query parity gate is demoted to a diagnostic; the acceptance test for a compressed package is a val evaluation through the runtime (eval_coreml.py) compared against the ONNX graph. The size decision is a product call among three options: raise the bundled budget to about 30 MB, raise the floor to iOS18 and write a custom exporter for grouped 4-bit, or switch to YOLOX-S at about 9 MB.

**Rationale:** Core ML float32 is decision-identical to ONNX (0.9828 precision, 0.8085 recall, 0.9242 mAP, 0.5465 false positives per image, count error 3, zero delta on all five). float16 costs 0.76 recall points, and int8 k-means adds only 0.13 more for half the size, so 26.4 MB is the best available trade. int8 uniform costs 5 recall points and 2 counts of error, which is why the earlier int8 result looked broken. int4 per tensor leaves the model unusable (7 detections against 324), and grouped palettization and int4 linear quantization both require iOS18. The old gate reported failure because it maximized over all 300 queries including background queries that flip across the threshold, so it was never measuring decisions.

**Trade-offs:** 26.4 MB is 11 MB over the budget, and the app is local-first with no download path, so the model ships in the bundle and the budget was set for a reason. Accepting about 30 MB is the cheapest path but needs the user's explicit call. An iOS18 floor drops iOS16 and 17 devices and needs an exporter the project does not have. YOLOX-S fits the size budget but its accuracy and false positive profile is worse, and its false positive numbers are not comparable because the labels are the limit (see the earlier entry). None of these should be decided before the dense eval set exists, since that set decides whether RF-DETR is worth 30 MB at all.

## 2026-10-22, Phase 4: raise the bundled model budget from 15 MB to 30 MB

**Context:** The 2026-10-22 Core ML work established that the smallest usable RF-DETR package at the iOS16 floor is 26.4 MB int8 k-means, and that the 15 MB budget cannot be met by any compression setting the current exporter can produce: int4 per tensor destroys the model, and grouped palettization and int4 linear quantization require iOS18. The 15 MB limit had been carried through the D1 and YOLOX decisions.

**Decision:** Raise the Phase 4 bundled model budget from 15 MB to 30 MB, and treat the 26.4 MB int8 k-means Core ML package as the size reference. The 15 MB limit in docs/requirements.md is superseded. This does not make the model shippable: the false positive and count error criteria remain unmeasured until the dense own-gym eval set exists, and the model choice stays open until then.

**Rationale:** The measured cost of the package is small and known: on full val at confidence 0.765 it scores 0.9822 precision, 0.7996 recall, 0.9167 mAP@0.5, 0.5567 false positives per image, and count error 3, against 0.9828 / 0.8085 / 0.9242 / 0.5465 / 3 for the canonical ONNX graph. Core ML float32 is decision-identical to ONNX, float16 costs 0.76 recall points, and int8 k-means adds 0.13 more at half the size. An 11 MB bundle increase buys the accuracy winner of the two trained architectures at a quantified 0.9 recall point cost, which is a better trade than dropping to YOLOX-S at about 9 MB with 3.34 false positives per image at the recall floor, or spending weeks on an iOS18 exporter that would also drop iOS16 and 17 devices.

**Trade-offs:** The app ships the model in the bundle because it is local-first with no download path, so this is an 11 MB app size increase on every install. It also weakens the pressure to keep the model small, so any future architecture change should re-justify its own size. The earlier entries that kept the 15 MB budget (D1, YOLOX-S) are historical and superseded on this point only; their accuracy findings stand.
