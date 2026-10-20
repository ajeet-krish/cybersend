# CyberSend Architecture

Last updated: 2026-10-20 (M2 plan, SwiftUI logbook)

Snapshot of the current design. Full DDL lives in docs/schema.sql. The TypeScript tree (src/ and app/) is frozen and serves as the behavioral port spec for the Swift port; it is never built into the app.

## Overview

Local first bouldering tracker, native iOS only, written in Swift. SwiftUI screens with UIKit gesture recognizers on the tagging canvas, GRDB over SQLite for storage, Core ML for on-device inference, AVFoundation for video. Zero accounts, hard offline. The approved schema, requirements (US numbers and budgets), ML training track, licenses, and the normalized-coordinate contract carry over unchanged from the React Native plan. Device floor is iOS 16 on iPhone 11 and newer, with the AI capability gate unchanged.

The app is a committed Xcode project (ios/CyberSend.xcodeproj) whose target consumes the local Swift package ios/CyberSendCore (products CyberSendDomain, CyberSendData, CyberSendFeatures). App sources live in ios/App. The deployment target is 16.0, so iOS 17 plus APIs are compile-time excluded; state uses ObservableObject and @Published because @Observable is iOS 17 only.

## Component Breakdown

| Component | Responsibility | Location |
|-----------|---------------|----------|
| Domain | Entities, grade normalization (rasch_lite), attempt rules, stats, import validation. Pure Swift, no GRDB or UIKit imports. | ios/Sources/Domain |
| Data | GRDB database, migrations, repositories, row records and mappers, backup serialization. The only SQL surface. | ios/Sources/Data |
| Features | Per-feature ObservableObject stores (logbook, sessions, gyms, grades, settings), backup and import services, feature flags, dormant board seam. | ios/Sources/Features |
| App | CyberSend app target: composition root, navigation, SwiftUI screens, theme, shared components, launch and migration-failure states. | ios/App |
| Tests | swift-testing suites for Domain, Data, Features (including stores). DataTests and store tests run against in-memory GRDB. | ios/Tests |
| App tests | XCTest unit smoke (CyberSendAppTests) and XCUITest smoke (CyberSendUITests) built by the Xcode project. | ios/CyberSendAppTests, ios/CyberSendUITests |
| ML tooling | Dataset build, training, ONNX export, eval harness. Stack independent, unchanged. | tools/train, tools/eval |
| Port spec | Frozen TypeScript implementation. Behavioral reference and source of golden fixtures. | src/, app/ |
| Model assets | Canonical ONNX plus Core ML deployment copies with manifest.json. | assets/models/ |

Dependency rule: Features depend on Domain and Data; the App target renders domain values and calls Features stores. Domain imports nothing from Data, Features, or UI. Repositories return domain models. Views never touch GRDB directly. Stores call repositories synchronously on the main actor and expose @Published state.

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
           files: photos/ videos/ backups/ exports/ under Application Support/CyberSend/
launch:    CyberSendApp -> AppBootstrap -> CyberSendDatabase.openDeviceDatabase (migrate)
           -> success: stores + TabView | failure: migration-failure screen (US-7)
quick-log: session screen tap -> SessionDetailStore.logAttempt -> AttemptRepository.logAttempt
           (one transaction: next attempt_no, domain rules, insert)
backup:    session close / scenePhase background -> BackupService.maybeWriteAutomaticBackup /
           runScheduledBackup (hourly throttle) -> .cybersend zip in backups/ (keep 10)
restore:   settings -> confirmation dialog -> fileImporter -> BackupService.restoreBackup
           (staging rehearsal, one transaction, media reconcile)
```

## File Structure

| Path | Purpose |
|------|---------|
| ios/CyberSend.xcodeproj | Committed Xcode project (objectVersion 77, file-system synchronized groups). Targets: CyberSend app, CyberSendAppTests, CyberSendUITests. Configurations: Development, Internal, Release via ios/Config/*.xcconfig. |
| ios/Package.swift | CyberSendCore package: CyberSendDomain, CyberSendData, CyberSendFeatures, CyberSendCoreTests. |
| ios/Sources/Domain/ | Models, grade, attempts, stats, validation. Port of src/domain with identical behavior. |
| ios/Sources/Data/ | GRDB setup, migrations, repositories, records and mappers. The only SQL surface. |
| ios/Sources/Features/ | Logbook stores (ObservableObject), backup, import, flags. |
| ios/App/ | App entry (CyberSendApp), composition root (AppEnvironment, AppBootstrap), navigation, screens per feature, theme, shared components, migration-failure screen, Info.plist. |
| ios/Resources/ | Assets.xcassets (app icon placeholder, accent color). |
| ios/Config/ | Base, Development, Internal, Release xcconfig files. |
| ios/CyberSendAppTests/ | XCTest smoke for the composition root. |
| ios/CyberSendUITests/ | XCUITest smoke: quick-log, history, settings and restore confirmation. |
| ios/Tests/ | swift-testing suites mirroring the Jest suites plus store tests; in-memory GRDB. |
| src/, app/ | Frozen TypeScript port spec. Never built into the app. |
| tools/eval, tools/train | ML tooling, unchanged. |
| assets/models/ | holds_detector.onnx (canonical), holds_detector.mlmodel (deployment copy), manifest.json. |
| docs/ | architecture, decisions, schema.sql, requirements, tests, research, reviews. |

## Data Layer

- Driver: GRDB 7 over the system SQLite. Device database: DatabasePool at Application Support/CyberSend/db/cybersend.sqlite.
- Storage root: Application Support/CyberSend/ with db/, photos/ (plus thumbs/), videos/, backups/, exports/. All stored uris are relative to this root. Backups leave the device through the share sheet only.
- Migrations: GRDB DatabaseMigrator runs named forward migrations (001_initial and so on), one transaction per migration, tracked in grdb_migrations plus a schema_migrations audit row per migration (US-7). No down migrations; restore is the rollback path.
- Pragmas at open: foreign_keys ON, journal_mode WAL, busy_timeout 5000.
- Entities: gyms, walls, boards, board_problems (dormant), climbs, holds, photos, videos, pose_keypoints, sessions, attempts, grade_norm_params, settings. DDL unchanged in docs/schema.sql. M2 adds no tables and no export tables (byte compatibility with the frozen spec).
- Grade storage: (grade_system_id, grade_level_id) references to grade_systems and grade_levels (US-9), built-ins seeded rows.
- Transactions: withTransaction helper on the writer; multi table writes (log attempt, import, restore, media sweep) are single transactions.

## App Layer (M2)

- Composition root: AppBootstrap opens the database and runs migrations at launch. Success builds AppEnvironment (document root, writer, Repositories, flag values, stores) and the three tab NavigationStacks. MigrationError.databaseNewerThanApp shows a guidance-only screen (no writes, US-7). Any other migration failure shows a screen with retry and restore-from-backup (the rollback left the prior schema intact).
- State: per-feature ObservableObject stores with @Published state, synchronous repository calls on the main actor, refresh on appear and after each write. No third-party dependencies. iOS 16 floor rules out @Observable.
- Navigation: TabView (Logbook, Sessions, Settings), each a NavigationStack with a typed route enum. Sheets: fall-hold picker, close-session (RPE), confirmations (delete attempt, delete session, restore). Restore is gated behind a destructive confirmation dialog (US-15.3, M2 review obligation).
- Quick-log: the open session screen is the quick-log surface (port spec app/session/[id].tsx). Choose climb, tap outcome (the tap saves), project and fail prompt for the fall hold with a skip. Budget: at most 4 taps and 5 s per attempt; one open session rule enforced by SessionRepository.create and surfaced on the Logbook screen.
- Settings: default gym, default grade scheme, appearance (system, light, dark, persisted), photo retention preference (keep originals default, enforced from M3), video retention label, feature flag toggles on non-release builds, export and backup entry points wired to Features/Backup.
- Backup hooks: session close and scenePhase background trigger the M1 BackupService entry points (hourly throttle, keep 10).
- Dark mode: theme colors for both appearances from day one, appearance override via preferredColorScheme, persisted in settings.

## Migration Plan (M0 to M6)

| Milestone | Scope | US mapping | Status |
|-----------|-------|-----------|--------|
| M0 | Decision lock, TypeScript tree frozen, GRDB migrations, test harness. | US-6, US-7 (setup) | Complete |
| M1 | Domain, data, backup port. Byte-compatible .cybersend archives. | US-7, US-13 to US-16 | Complete (158 tests green) |
| M2 | App target plus SwiftUI logbook: gyms, grades, climbs, sessions, attempts, quick-log, history, settings, restore confirmation. | US-8 to US-12, US-22, US-24 to US-26 | In progress (plan of record) |
| M3 | Photo capture and tagging MVP. Phase 2 gate unchanged. | US-17 to US-26 | Not started |
| M4 | Grade normalization port: rasch_lite, translator, data-sufficiency gate. | US-27 to US-30 | Not started |
| M5 | Hold detection: coremltools pipeline, parity gate, eval gates. | US-31 to US-35 | Not started |
| M6 | BoulderVision video analysis behind the experimental flag. | US-36 to US-40 | Not started |

All US numbers and numeric budgets from docs/requirements.md carry over unchanged. Gate for M2: quick-log at most 4 taps and at most 5 s, cold start at most 2.5 s (measured in dogfood).

## ML Pipeline

Unchanged from the migration decision: ONNX canonical, .mlmodel deployment copy behind a parity gate (box delta <= 1 px, logit delta recorded), VNCoreMLRequest with .cpuAndNeuralEngine plus the Xcode Core ML performance report, NMS in Swift, YOLOX-Nano bias via the ML-D1 comparison, pose via the Phase 0 spike (Vision versus TFLite/MoveNet). Capability gate and eval harness (tools/eval) unchanged; see docs/requirements.md section 6 for budgets.

## Canvas and Coordinates

Unchanged: domain coordinates normalized 0..1 (x_norm, y_norm, radius_norm over image width); pixels only in the UI layer; UIKit gestures on the SwiftUI canvas (M3); preprocess golden vectors shared with tools/eval.

## Feature Flags

Build configurations Development, Internal, Release with xcconfig compile-time defaults merged with settings overrides (settingsKeyFlagOverrides) in Features/Flags. BoulderVision is hard gated in release; ai_hold_detection and ai_pose_analysis ship off and toggle on via the flags screen on non-release builds.

## Backup and Export

Unchanged format: .cybersend zip (manifest.json, data.json, media/), byte compatible with the frozen TypeScript spec, CSV export (RFC 4180), staging import with rehearsal, foreign key check, pre-import snapshot, media reconcile with sha256. Rotation keeps the last 10. M2 housekeeping: foreign_key_check lives in DumpRepository, atomic file writes, export-side safe-relative-path guard, zip entry and size caps, tolerant throttle timestamp parsing.

## Test Strategy

- swift-testing for package code (Domain, Data, Features including stores). DataTests and store tests run on in-memory GRDB via makeTestRepositories.
- Import and export round-trip tests use golden .cybersend fixtures shared with the frozen TypeScript spec (M1, unchanged).
- XCUITest is the e2e tool (decided at M2; Maestro does not carry over). Smoke set only: quick-log with tap accounting, session history, settings with restore confirmation. Deterministic via Debug-only launch-argument seeding.
- App-level XCTest smoke covers the composition root and launch states.
- ML regression stays in tools/eval (unchanged).

## Risks and Mitigations

- iOS 16 floor versus newer SwiftUI APIs. Mitigation: deployment target 16.0 makes iOS 17 plus API use a compile error; store tests cover logic on macOS; dogfood on device for runtime behavior.
- Swift 6 strict concurrency with GRDB in views. Mitigation: stores are @MainActor with synchronous repository calls (measured fast at personal scale); only Sendable values (Repositories, URLs, Data) cross into detached tasks for backups.
- Hand-authored project.pbxproj drift. Mitigation: minimal objectVersion 77 file with synchronized groups, validated by xcodebuild -list and plutil -lint on every change.
- Self-referencing local package (project inside the package directory). Mitigation: if Xcode refuses, relocate the package to ios/CyberSendCore and update commands and docs (recorded in decisions.md).
- Cold start budget (2.5 s). Mitigation: migration runs once at launch and is small; measure in dogfood; move bootstrap off the main actor if needed.
- XCUITest flakiness. Mitigation: three smoke tests maximum, launch-argument seeding, accessibility identifiers instead of layout queries.
