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

## 2026-10-21, Phase 4: D1 accuracy winner is not shippable, decision pending

**Context:** D1 trained two Apache-2.0 candidates and spent the single frozen test run on RF-DETR-Nano. RF-DETR passes the three accuracy thresholds (precision 0.9509, recall 0.8788, mAP@0.5 0.9130) and the count-error limit (1.0), but produces 1.8832 false positives per image against a 0.5 budget, and its 28.9M parameters put an int8 build at roughly 29 MB against a 15 MB budget. YOLOX-Nano meets size (about 1 MB int8) and mAP, but cannot reach 0.80 recall at any threshold (0.80 recall costs precision down to 0.7168).

**Decision:** Treat Phase 4 as accuracy-decided but shipment-blocked. RF-DETR is the model of record for evaluation and the target of the Core ML feasibility check; it is not a shippable model. No gate threshold is being revised now. The decision between rescaling or retraining YOLOX and revising a budget (with recorded justification) waits until the Core ML feasibility result is in, because a conversion failure removes RF-DETR from consideration entirely and the two branches lead to different work.

**Rationale:** The false positive rate is the real product problem: 1.88 wrong boxes per photo at the operating point would make the prefill feature annoying enough that users turn it off, which defeats the tagging accelerator. Size is a harder constraint than it looks because Core ML weight compression does not beat one byte per parameter. Proceeding with conversion first costs hours and settles whether the accuracy winner is even deployable, which determines what the next training iteration must optimize.

**Trade-offs:** Delaying the YOLOX retrain risks spending device and conversion effort on a model that may be replaced anyway. Choosing RF-DETR now would mean shipping a feature that fails two of its own quality budgets, so that is not available. The false positive gap may improve with a higher operating threshold on val, but that trades directly against the recall floor, so it is not a free fix.
