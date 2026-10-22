# CyberSend Architecture

Last updated: 2026-10-20 (M3 plan, photo capture and hold tagging)

Snapshot of the current design. Full DDL lives in docs/schema.sql (v1) plus the M3 Migration 002 delta below. The TypeScript tree (src/ and app/) is frozen and serves as the behavioral port spec; it is never built into the app.

## Overview

Local first bouldering tracker, native iOS only, Swift. SwiftUI screens with UIKit gesture recognizers on the tagging canvas, GRDB over SQLite, Core ML for on-device inference, AVFoundation for video. Zero accounts, hard offline. Device floor is iOS 16 on iPhone 11 and newer. The app is ios/CyberSend.xcodeproj (targets CyberSend, CyberSendAppTests, CyberSendUITests) consuming the local package ios/CyberSendCore (products CyberSendDomain, CyberSendData, CyberSendFeatures). Deployment target 16.0, so state is ObservableObject plus @Published and iOS 17 plus APIs are compile-time excluded.

## Component Breakdown

| Component | Responsibility | Location |
|-----------|---------------|----------|
| Domain | Entities, grade normalization, attempt rules, stats, import validation, canvas coordinate geometry (M3). Pure Swift, no GRDB or UIKit. | ios/Sources/Domain |
| Data | GRDB database, migrations (001, 002), repositories, records and mappers, backup serialization. The only SQL surface. | ios/Sources/Data |
| Features | Per-feature ObservableObject stores, photo ingest and media storage (M3), tagging store, backup and import services, flags. | ios/Sources/Features |
| App | Composition root, navigation, SwiftUI screens, theme, UIKit canvas and camera representables (M3), launch states. | ios/App |
| Tests | swift-testing suites (Domain, Data, Features). DataTests and store tests run on in-memory GRDB. | ios/Tests |
| App tests | XCTest smoke (CyberSendAppTests) and XCUITest smoke (CyberSendUITests). | ios/CyberSendAppTests, ios/CyberSendUITests |
| ML tooling | Dataset build, training, ONNX export, eval harness. Stack independent, unchanged. | tools/train, tools/eval |
| Port spec | Frozen TypeScript implementation, behavioral reference and golden fixture source. | src/, app/ |

Dependency rule: Features depend on Domain and Data; the App target renders domain values and calls Features stores. Domain imports nothing from Data, Features, or UI. Repositories return domain models. Views never touch GRDB and never call repositories directly (stores only). Stores call repositories synchronously on the main actor and expose @Published state.

## Data Flow

```
capture:   CameraCaptureView (UIImagePickerController camera) or PhotoImportSheet (PhotosPicker)
           -> PhotoIngest (ImageIO: 2048 px working copy, 256 px thumb, optional original, pixels up)
           -> MediaStorage files under Application Support/CyberSend/photos/
           -> MediaRepository.createPhoto -> photos row (uri = working copy, original_uri per retention)
tagging:   TaggingView -> TaggingCanvasView (UIScrollView + UIImageView + CAShapeLayer)
           -> UIKit gestures -> TaggingStore (bounded undo) -> HoldRepository
           -> holds rows (normalized, source=manual) + climb_holds rows (membership, beta sequence)
quick-log: session screen -> Fail/Project tap -> FallHoldSheet (real holds, optional photo canvas)
           -> hold row tap or Skip -> SessionDetailStore.logAttempt -> AttemptRepository
           (fall hold membership validated against climb_holds, one transaction)
fall map:  attempt data -> hold positions -> heatmap overlay on the climb photo (stats screen, US-23)
launch:    CyberSendApp -> AppBootstrap -> migrate (001, 002) -> MediaSweep (orphan rows and files,
           async after first frame) -> stores + TabView
backup:    export payload v2 (climb_holds table, photos.original_uri) + media/ in the .cybersend zip
restore:   import v1 or v2 or legacy -> payload migration -> staged transaction -> media reconcile
```

## File Structure

| Path | Purpose |
|------|---------|
| ios/CyberSend.xcodeproj | Committed Xcode project (objectVersion 77, synchronized groups). Configurations Development, Internal, Release via ios/Config. |
| ios/Package.swift | CyberSendCore package: CyberSendDomain, CyberSendData, CyberSendFeatures, CyberSendCoreTests. |
| ios/Sources/Domain/ | Models, grade, attempts, stats, validation, Canvas/CanvasGeometry (M3 coordinate contract). |
| ios/Sources/Data/ | GRDB setup, Migrations 001 and 002, repositories, records and mappers. |
| ios/Sources/Features/ | Logbook stores, Photos (MediaStorage, PhotoIngest, MediaSweep, PhotoStore), Tagging (TaggingStore), Backup, Flags. |
| ios/App/ | App entry, composition root, navigation, screens, theme, UI/Canvas and UI/Camera representables, Info.plist. |
| ios/Tests/ | swift-testing suites plus golden fixtures (data_native_v1 pinned, data_native_golden_v2 current). |
| ios/CyberSendAppTests, ios/CyberSendUITests | Composition root smoke and XCUITest smoke (quick-log, history, settings/restore, tagging, fall hold). |
| src/, app/ | Frozen TypeScript port spec. Never built into the app. |
| tools/eval, tools/train | ML tooling, unchanged. |
| docs/ | architecture, decisions, schema.sql, requirements, tests, research, reviews. |

## Data Layer

- Driver: GRDB 7 over system SQLite. Device database: DatabasePool at Application Support/CyberSend/db/cybersend.sqlite. Pragmas: foreign_keys ON, WAL, busy_timeout 5000.
- Storage root: Application Support/CyberSend/ with db/, photos/ (working/, thumbs/, originals/), videos/, backups/, exports/. Stored uris are relative to this root. Backups leave the device only through the share sheet.
- Migrations: forward only, one transaction each, schema_migrations audit row plus PRAGMA user_version per migration (US-7). No down migrations; restore is the rollback path.
- Migration 002 (M3): creates climb_holds (climb_id, hold_id, sequence, PK both, FK CASCADE both, index on hold_id) backfilled from holds.climb_id (sequence = ordinal), and adds photos.original_uri TEXT. holds.climb_id stays as the origin climb (photo and lifecycle association); membership and beta order live in climb_holds (US-20).
- Photo files: uri = 2048 px pixels-up JPEG working copy (the coordinate source image), thumb_uri = 256 px thumb, original_uri = preserved original when retention is keep originals. photos.width/height describe the working copy.
- Entities: unchanged set from docs/schema.sql plus climb_holds. Videos untouched in M3.
- Transactions: multi table writes (log attempt, tagging save, import, restore, media sweep) are single transactions.

## App Layer (M3)

- Photo stack: PhotosUI PhotosPicker for library import (out of process, no photo library permission), UIImagePickerController camera behind a CameraCapturing seam, Debug only synthetic capture feeding the identical ingest pipeline for XCUITest. Info.plist gains NSCameraUsageDescription only. Camera denial degrades to a settings deep link; the library path needs no permission (US-17).
- Ingest: ImageIO thumbnail decode (CGImageSourceCreateThumbnailAtIndex with orientation transform) bakes EXIF into pixels; working copy at 2048 px long edge, thumb at 256 px, JPEG. Retention (settingsKeyPhotoRetention) is enforced at tagging save: discard originals deletes the stored original and leaves original_uri nil.
- Canvas: TaggingCanvasView (UIViewRepresentable) with UIScrollView zoom/pan, UIImageView photo, CAShapeLayer holds overlay. Gestures: scroll pan, pinch, single tap (place or select), double tap (reset zoom), hold drag (delegate arbiter). Roles render by shape and color plus letter (colorblind safe); a VoiceOver holds list provides full editing. Bounded undo stack in TaggingStore.
- Coordinates: normalized 0..1 over the pixels-up working copy; radius_norm over width; pixels only in UI. Pure helpers in Domain/Canvas/CanvasGeometry.swift (fitContentBox, normToScreen, screenToNorm, hitTest) with golden vector tests. Letterbox math is M5 only (tools/eval letterboxToSourceBox, then divide by source width and height).
- Navigation: LogbookRoute gains the tagging screen; ClimbEditor gains photo and holds sections (add, replace, delete photo with confirmation; link and unlink holds across climbs). FallHoldSheet lists real holds and can show the climb photo canvas; hold row tap or Skip stays one tap, so the quick-log budget of 5 taps survives.
- Launch: MediaSweep removes photo rows whose working copy is missing and files with no row, async after first frame so the 2.5 s cold start budget is untouched.

## App Layer (UI overhaul)

Dark first Dracula palette with an Alucard light variant (Theme.swift); SettingsStore resolves an unset appearance to dark. Five tabs: Logbook, Problems, Stats, Sessions, Settings. Settings groups Appearance, then Defaults, then Gyms and Grade schemes.

Logbook home (LogbookHomeView) composes four blocks over one snapshot from HomeOverviewStore: the session card (open session, or a gym menu plus Start session), the consistency heatmap, the last three sessions, and the last three climbs. The heatmap is 20 columns of 7 local days ending on the current week, one filled day per session start, future days in the current week drawn as holes. Recent climbs means most recently attempted: the store walks AttemptRepository.listRecent newest first and keeps the first occurrence of each climb, then resolves names, grades, and totals through the repositories. The store is the only home data source; the view holds no queries.

Problems tab (ProblemsCatalogView, ProblemDetailView) is a catalog over climbs for the selected gym. Adding and editing push ClimbEditorView with noun "problem"; the editor's grade scheme and level are menu pickers, and the details field is climbs.notes. The detail screen shows the photo hero, grade, angle, color, details, and the complete attempt history newest first with per attempt RPE and notes, plus edit, tag holds, and archive. Archiving is the only removal there; delete stays in the editor and remains blocked while attempts exist. The problems stack also registers LogbookRoute.tagging because the shared editor links to it.

Session editor (SessionDetailView) picks the quick log climb from a menu showing the selected climb and grade, adds and edits a problem inline through ClimbEditorView in a sheet (the create path passes the session's gym and keeps the sheet open in edit mode so the photo is reachable), and logs outcomes with Flash, Send, and Fail side by side plus a per attempt effort picker. Per attempt RPE is attempts.rpe (nullable, 1 to 10) and the Project outcome is retired: historical rows were rewritten to fail by Migration 003. Session media (SessionMediaSection) sits on every session screen: photos through PhotoStore.addSessionPhoto with a nil climb, videos imported as untouched bytes under videos/ with a videos row (session_id, dimensions, duration, retention keep) and AVKit playback. On a live session the quick log controls come first; on a closed session the gallery leads.

## Migration Plan (M0 to M6)

| Milestone | Scope | US mapping | Status |
|-----------|-------|-----------|--------|
| M0 | Decision lock, TypeScript frozen, migrations, test harness. | US-6, US-7 (setup) | Complete |
| M1 | Domain, data, backup port. Byte compatible .cybersend. | US-7, US-13 to US-16 | Complete (158 tests) |
| M2 | SwiftUI logbook: gyms, grades, climbs, sessions, attempts, quick-log, history, settings, restore gate. | US-8 to US-12, US-22, US-24 to US-26 | Complete (190 package tests) |
| M3 | Photo capture and hold tagging MVP. Phase 2 gate unchanged. | US-17 to US-26 (US-23 open question) | In progress (plan of record) |
| M4 | Grade normalization port: rasch_lite, translator, data-sufficiency gate, US-26.1 grade history. | US-27 to US-30 | Not started |
| M5 | Hold detection: coremltools pipeline, parity gate, eval gates. | US-31 to US-35 | Not started |
| M6 | BoulderVision video analysis behind the experimental flag. | US-36 to US-40 | Not started |

Gates: M2 quick-log at most 5 taps (3 when the climb is already selected) and at most 5 s, cold start at most 2.5 s (dogfood). M3 Phase 2 gate: canvas at least 55 fps at 100 holds on 2048 px, tap placement error at most 3 px at 1x, three dogfooded gym sessions with zero data loss, airplane mode and proxy verified zero network, 2048 px policy, dark mode.

## ML Pipeline

ONNX is the canonical artifact and the `.mlmodel` deployment copy sits behind two gates: decision-space parity against PyTorch (hold scores and active-query boxes within 1e-3) and the frozen-split quality gate. tools/eval declares per-model contracts: RF-DETR uses ImageNet normalization, normalized cxcywh output, and no NMS; YOLOX uses raw 0..255 input, cxcywh pixels, and harness-side NMS at IoU 0.65. Both D1 exports run end to end through that harness.

D1 status: RF-DETR-Nano passes the three accuracy thresholds on the frozen test split (0.9509 precision, 0.8788 recall, 0.9130 mAP@0.5) but fails the false positive budget (1.88 per image versus 0.5) and cannot meet the 15 MB int8 size budget at 28.9M parameters. YOLOX-Nano fits the size budget but fails recall at every threshold. Core ML conversion of RF-DETR is the open feasibility question, with two GridSample nodes in the decoder cross attention. The app path stays VNCoreMLRequest with .cpuAndNeuralEngine, NMS in Swift, and the letterboxToSourceBox coordinate contract, all unchanged until a model is shippable.

## Feature Flags

Development, Internal, Release xcconfig defaults merged with settings overrides (settingsKeyFlagOverrides). BoulderVision hard gated in release; ai_hold_detection and ai_pose_analysis ship off. M3 adds no flags; the Debug only synthetic capture and seeding paths are compiled by DEVELOPMENT and unreachable in Internal and Release.

## Backup and Export

Format unchanged (.cybersend zip: manifest.json, data.json, media/), but the payload is schema_version 2 from M3: the tables list gains climb_holds and photos gains original_uri. Import accepts legacy TS shape, native v1, and v2; a registered PayloadMigration from 1 synthesizes climb_holds from holds.climb_id and leaves original_uri nil, so every older export and fixture imports losslessly. v1 payloads stay byte identical (data_native_v1.json is pinned as an import fixture); v2 export bytes are pinned by data_native_golden_v2.json, cross-checked against Node JSON.stringify formatting. Media in backups covers working copy, thumb, and retained original. Rotation keeps 10.

## Test Strategy

- swift-testing for package code; in-memory GRDB via makeTestRepositories; synthetic CGImages for ingest tests (EXIF orientations 1, 3, 6, 8; 8000x6000 memory path).
- Golden fixtures: v1 export bytes pinned as import fixture, v2 export bytes pinned current; legacy translation tests unchanged.
- XCUITest smoke set: quick-log tap accounting (including a hold row as the fifth tap), session history, settings catalog, settings and restore, synthetic capture plus tagging three holds with roles, fall-on-hold from real holds, and the problems catalog (list, history, archive, archived filter). System pickers (camera, PhotosPicker) are never driven by tests; Debug seams feed the identical pipeline.
- Canvas performance: DEVELOPMENT FPS HUD (CADisplayLink) plus a seeded 100 hold fixture; measure in dogfood on device, simulator is a documented proxy. Tap placement accuracy is proven by round-trip unit tests plus a deterministic XCUITest coordinate check.
- ML regression stays in tools/eval.

## Risks and Mitigations

- 48 MP camera original re-encode is the largest memory spike (about 250 MB peak). Mitigation: retention aware (discard originals never decodes full resolution), off main actor, autoreleasepool, one ingest at a time, graceful failure on memory pressure.
- EXIF rotation corrupting coordinates. Mitigation: orientation baked into pixels at ingest; only the pixels-up working copy defines the coordinate space; synthetic orientation tests.
- Gesture conflicts on the canvas. Mitigation: delegate arbitration with shouldBegin hit tests and require(toFail:) for single versus double tap; XCUITest and dogfood coverage.
- Export compatibility break at payload v2. Mitigation: additive tables only, PayloadMigration 1 to 2, v1 fixtures pinned forever, frozen TS tree untouched.
- Simulator has no camera. Mitigation: PhotosPicker plus synthetic capture share the ingest pipeline; camera verified in dogfood only; documented in docs/tests.md.
- Canvas fps misses budget on iPhone 11. Mitigation: CAShapeLayer and UIImageView redraw discipline, FPS HUD with 100 hold seed, simplify selection handles at high zoom if needed.
- Quick-log budget regression from the richer fall hold sheet or the climb dropdown. Mitigation: single tap row save preserved, the dropdown costs one extra tap only when the climb changes, and the tap-accounting UI test fails on any extra tap.
