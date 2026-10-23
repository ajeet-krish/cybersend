# CyberSend Architecture

Last updated: 2026-10-21 (pose pipeline M6 plan of record)

Snapshot of the current design. Full DDL lives in docs/schema.sql (v1) plus the M3 Migration 002 delta below. The TypeScript tree (src/ and app/) is frozen and serves as the behavioral port spec; it is never built into the app.

## Overview

Local first bouldering tracker, native iOS only, Swift. SwiftUI screens with UIKit gesture recognizers on the tagging canvas, GRDB over SQLite, Core ML for on-device inference, AVFoundation for video. Zero accounts, hard offline. Device floor is iOS 16 on iPhone 11 and newer. The app is ios/CyberSend.xcodeproj (targets CyberSend, CyberSendAppTests, CyberSendUITests) consuming the local package ios/CyberSendCore (products CyberSendDomain, CyberSendData, CyberSendFeatures). Deployment target 16.0, so state is ObservableObject plus @Published and iOS 17 plus APIs are compile-time excluded.

## Component Breakdown

| Component | Responsibility | Location |
|-----------|---------------|----------|
| Domain | Entities, grade normalization, attempt rules, stats, import validation, canvas coordinate geometry (M3). Pure Swift, no GRDB or UIKit. | ios/Sources/Domain |
| Domain (pose) | Pure metrics over a typed pose track: body scale, smoothing, derivatives, attempt window, fall, dyno, cut feet, hesitation map, camera class. No Vision import. | ios/Sources/Domain/Pose |
| Data | GRDB database, migrations (001, 002), repositories, records and mappers, backup serialization. The only SQL surface. | ios/Sources/Data |
| Features | Per-feature ObservableObject stores, photo ingest and media storage (M3), tagging store, backup and import services, flags. | ios/Sources/Features |
| Video analysis | Frame reading, Vision pose adapter, analysis service (actor), quality and camera class, library and review stores. | ios/Sources/Features/VideoAnalysis |
| App | Composition root, navigation, SwiftUI screens, theme, UIKit canvas and camera representables (M3), launch states. | ios/App |
| Video analysis UI | Guided recorder, review screen with overlay and scrubbing timeline, pose overlay rendering, session card, videos library. | ios/App/VideoAnalysis |
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
| ios/App/ | App entry, composition root, navigation, screens, theme, shared components (Screen, Card, Row, FlowLayout, themed fields), UI/Canvas and UI/Camera representables, Info.plist. |
| ios/Resources/Assets.xcassets | AppIcon (white climbing mark on a purple gradient, 1024 single size, no alpha) and AccentColor. |
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
- Migration 005 (UI overhaul): climbs.categories TEXT nullable, the comma separated category tokens in declaration order. Unknown tokens parse as nothing so a row from a newer build stays readable.
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

Problems tab (ProblemsCatalogView, ProblemDetailView) is a catalog over every gym, narrowed by a filter bar: gym, level, category, and climb status (sent, flash, ongoing). The chips wrap through FlowLayout (a small Layout) instead of a horizontal scroller, because four chips did not fit one phone width and the status filter was hidden. The list loads once and filters in memory; level options are ordered by scheme and level rank, and each row shows the thumbnail, name, grade chip, gym, categories, Sent badge, attempt count, and last tried. ProblemCatalogStore owns the filters and clears ones that no longer match after a reload. Adding and editing push ClimbEditorView with noun "problem".

The editor is one form for create and edit: Name, a Details group (gym, grade scheme, level, wall angle, colour circuit), Notes, a Climb category toggle grid (the fixed ClimbCategory list), Photo, Holds, and for an existing problem a Manage card with Archive and Delete side by side. Tagging lives only in the Holds row (the row detail states the hold count once, or None tagged); the photo section no longer carries a second link, and an untagged photo empty state is one tappable card, not a card plus a duplicate button. Picking a photo while the problem is still unsaved creates it first (save, then ingest) and flips the screen into edit mode, so the create screen has the same photo and holds sections. The gym is a picker, so a problem can be created in or moved to any gym; the repository validates the target gym.

Fields use the themedField modifier (raised surface, card border) rather than the system rounded border, which fills with the page background and renders as a black hole on a dark card. Outcome buttons use AttemptOutcome.themeColor: a soft tint, matching border, and coloured label for flash (info), send (success), and fail (danger), so the action matches the attempt badge it writes and the three buttons are not interchangeable accents; a disabled outcome (flash after the first attempt, Edit Problem with no target) uses a faint tint and tertiary text.

The detail screen shows the photo hero, gym, name with grade, category chips, a read only View hold stats sheet (role counts and each tagged hold with its role and percent across and down the photo), the user notes, the complete attempt history newest first with per attempt RPE, and edit plus archive. Tag holds is not on the detail screen; tagging stays in the editor. Archiving is the only removal there; delete stays in the editor and remains blocked while attempts exist. The problems stack also registers LogbookRoute.tagging because the shared editor links to it.

Session editor (SessionDetailView) lists every climb added to the session as a workout style card (name, grade chip, categories, attempts so far) plus Add Climb, Edit Problem, and New Problem side by side; Add Climb is a menu of the gym's climbs not yet in the session, and selecting a card targets it for logging. Membership lives in SessionDetailStore: an added climb id list rebuilt from the session's attempts on every reload, so a climb added and never tried is remembered for the life of the screen while a tried climb is always in the session. The Log attempt card carries the target climb, Flash, Send, and Fail side by side, and a per attempt effort picker. The Attempts list reads climb name first, then the result, effort, and fall hold, and each row opens the edit sheet while the session is open, not only after it closes, so an outcome, effort, fall hold, or note can be corrected on the spot. Creating a problem inline goes through ClimbEditorView in a sheet (the create path passes the session's gym and keeps the sheet open in edit mode so the photo is reachable) and the saved problem is added to the session and targeted. Per attempt RPE is attempts.rpe (nullable, 1 to 10) and the Project outcome is retired: historical rows were rewritten to fail by Migration 003. Session media (SessionMediaSection) sits on every session screen: photos through PhotoStore.addSessionPhoto with a nil climb, videos imported as untouched bytes under videos/ with a videos row (session_id, dimensions, duration, retention keep) and AVKit playback. On a live session the quick log controls come first; on a closed session the gallery leads.

## Migration Plan (M0 to M6)

| Milestone | Scope | US mapping | Status |
|-----------|-------|-----------|--------|
| M0 | Decision lock, TypeScript frozen, migrations, test harness. | US-6, US-7 (setup) | Complete |
| M1 | Domain, data, backup port. Byte compatible .cybersend. | US-7, US-13 to US-16 | Complete (158 tests) |
| M2 | SwiftUI logbook: gyms, grades, climbs, sessions, attempts, quick-log, history, settings, restore gate. | US-8 to US-12, US-22, US-24 to US-26 | Complete (190 package tests) |
| M3 | Photo capture and hold tagging MVP. Phase 2 gate unchanged. | US-17 to US-26 (US-23 open question) | In progress (plan of record) |
| M4 | Grade normalization port: rasch_lite, translator, data-sufficiency gate, US-26.1 grade history. | US-27 to US-30 | Not started |
| M5 | Hold detection: coremltools pipeline, parity gate, eval gates. | US-31 to US-35 | Not started |
| M6 | BoulderVision Pose v1: Vision pose extraction, analysis records (migration 006), Tier A metrics, guided recorder, review UI, gated comparison. Hold contact is Pose v2. | US-36 to US-40, US-40a | Not started |

Gates: M2 quick-log at most 5 taps (3 when the climb is already selected; adding a climb from the session costs the two menu taps) and at most 5 s, cold start at most 2.5 s (dogfood). M3 Phase 2 gate: canvas at least 55 fps at 100 holds on 2048 px, tap placement error at most 3 px at 1x, three dogfooded gym sessions with zero data loss, airplane mode and proxy verified zero network, 2048 px policy, dark mode.

## ML Pipeline

ONNX is the canonical artifact and the `.mlmodel` deployment copy sits behind two gates: decision-space parity against PyTorch (hold scores and active-query boxes within 1e-3) and the frozen-split quality gate. tools/eval declares per-model contracts: RF-DETR uses ImageNet normalization, normalized cxcywh output, and no NMS; YOLOX uses raw 0..255 input, cxcywh pixels, and harness-side NMS at IoU 0.65. Both D1 exports run end to end through that harness.

D1 status: RF-DETR-Nano passes the three accuracy thresholds on the frozen test split (0.9509 precision, 0.8788 recall, 0.9130 mAP@0.5) but fails the false positive budget (1.88 per image versus 0.5) and cannot meet the 15 MB int8 size budget at 28.9M parameters. YOLOX-Nano fits the size budget but fails recall at every threshold. Core ML conversion is measured: rfdetr's exporter produces an iOS16 mlprogram package that passes decision-space parity against ONNX at float32 (8.31e-4) and runs warm at 41 to 50 ms on the M5 with all compute units, while weight compression breaks parity (float16 2.96e-1, int8 4.54e-1, int4 9.77e-1). The deployment copy therefore stays ONNX-canonical with a float32 Core ML package, both over the size budget, and the app path stays VNCoreMLRequest with .cpuAndNeuralEngine, NMS in Swift, and the letterboxToSourceBox coordinate contract, all unchanged until a model is shippable.

## Pose Pipeline (M6, plan of record)

Frame walking is AVAssetReader with AVAssetReaderTrackOutput at 720 px long edge and 32BGRA, so the downscale happens in the decode path and Vision never sees a full resolution buffer. Orientation comes from the track preferredTransform, never from the device orientation, because a portrait clip shot on a phone usually carries a 90 degree transform and ignoring it rotates every keypoint without producing an error. Sources above 60 fps (120 and 240 fps slow motion) are strided so the analysis rate stays at or below 60 Hz while presentation timestamps are preserved; the stored track is decimated to 30 Hz and event timestamps keep full resolution.

One VNSequenceRequestHandler per clip with the request reused across frames, the request revision recorded on the analysis, and an autoreleasepool per frame. Vision returns normalized coordinates over the buffer it is given, which shares the source aspect ratio, so the pose path needs no letterbox math (unlike the hold detector contract).

Metrics live in Domain and take a PoseTrack value, not a pixel buffer, so they are unit testable in CI where no camera exists, and so a Core ML pose model can replace Vision without touching the math. The seams are protocol VideoFrameReading (frame source) and protocol PoseDetecting (detector). The analysis service is an actor; progress is published to the main actor; cancellation is cooperative and resumption restarts from the last committed checkpoint.

Storage is video_analyses (one row per video: algorithm_version, vision_revision, sampling_hz, camera_class, coverage, packed Float16 track blob) plus analysis_events (type, start and end ms, joint, normalized position, value, confidence). The blob is about 103 KB for a 30 s clip at 30 Hz, which is why the row per frame pose_keypoints design is retired rather than scaled. Export carries analyses and events, not the blob.

PoseAnalysisPipeline is the only entry point that writes an analysis: it runs extraction, Tier A metrics, and the repository save as one actor-isolated call, sets videos.pose_status to running, done, or failed, and turns the metric warnings into comma separated quality flags. A track that yields no metrics is still stored, because re-extracting later is the expensive step; such a row is forced to camera_class handheld so an absent classification can never unlock comparison, and it carries metrics_unavailable.

Camera stability class is computed per clip from global track drift and gates comparison: static and near static clips support metric comparison and spatial side by side, handheld clips support relative metrics only and are labelled as such in the UI. The feature stays behind the ai_pose_analysis flag, off by default, with the recorder and review surfaces compiled out of release until the graduation criteria in requirements section 6 are met.

## Guided Capture (P4)

Recorder is AVCaptureSession with the back wide camera and AVCaptureMovieFileOutput, portrait rotation applied to both the movie connection and the preview connection so the file and the preview agree. There is no audio input: a boulder clip is silent by nature and leaving audio out means the recorder never asks for the microphone.

Format policy prefers 1080p60, then 1080p30, then a 720p floor, and never prefers 4K: the analysis path downsamples to 720 px long edge and the clip is kept, so a larger format only costs storage. The selection runs over plain CaptureFormat values and is unit tested; the device format is chosen by index from that result. A device with nothing usable fails with a readable error rather than recording something the analysis cannot read.

The level badge is CoreMotion gravity projected onto the device x axis (roll), with a two degree tolerance. CoreMotion exists only in the app target, so the roll math, the guidance text, the clock, and the framing box live in Features/Capture and run in CI on macOS. Tap to focus converts the preview layer point to capture device coordinates and locks focus and exposure; a reset returns to continuous autofocus, which is what a climber moving between holds needs.

Recording stops at 90 s in the UI and at 95 s in the movie output, so a forgotten recording cannot fill the phone even if the screen stops updating. The finished file is adopted, not read: MediaStorage.adoptVideo moves the temporary .mov into videos/ and the row is created with pose_status pending, so a recorded clip travels the same path a library clip does and the analysis queue can pick it up by status.

The simulator has no camera, so the recorder's AVFoundation paths are not covered by tests. The pure rules are, and the camera itself is a dogfood obligation recorded in docs/tests.md. The XCUITest camera seam stays the synthetic photo source; it never drives a real capture session.

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
