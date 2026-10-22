# CyberSend Requirements

Last updated: 2026-10-19

Positioning of record: "The climbing tracker that knows where you fall, not just what you climb, and never asks you to make an account." Personal tool first, then shippable product. iOS first. Hard local-first, zero accounts.

User decisions applied 2026-10-19:
- App Store submission is the eventual goal. Licensing discipline required for Phase 4 and Phase 5 equivalents.
- Kilter integration is CUT from the roadmap. Board-generic schema fields remain so it can return later.
- Hold detection model path: Apache-2.0 self-trained (YOLOX-Nano or RF-DETR-Nano on the merged climbtag, blackcreed, and pwals datasets plus own labeled gym photos). No Ultralytics weights.
- Device floor: iOS 16, iPhone 11 and newer. Older devices get core logging with AI disabled.
- Defaults confirmed: single profile in v1 (schema stays profile_id-ready), app-local rotating backups plus manual export (iCloud Drive opt-in fast follow), V-scale primary grade scheme, ML acceptance thresholds accepted as written.

## 1. Personas and Primary Use Flows

### Personas

| ID | Persona | Description | Success Signal |
|----|---------|-------------|----------------|
| P1 | Ajeet, the data-driven gym boulderer (primary) | Intermediate climber (V4 to V6 range), climbs 2 to 4 times per week at one to two gyms with different grade sets, iPhone power user, privacy-first, wants to know which holds and positions cause falls | Logs every real session for 4+ consecutive weeks and uses the fall heatmap to choose projects |
| P2 | The project worker (secondary) | Climber fixated on a few hard projects; cares per-attempt fall location, attempt counts, beta comparison | Logs 20+ attempts on a single climb with fall holds and reads the per-climb fall map |
| P3 | The board specialist (deferred, Kilter cut) | Board user who wants offline board session logging | Deferred with Phase 5 cut; schema stays board-ready |
| S1 | Bystanders and gym policy (stakeholder) | People and walls captured in photos/videos; gym filming policies | Photos and video never leave the device, never require an account, deletable individually or in bulk |

Out-of-scope personas for v1: coaches, route setters, social/competitive climbers, gym owners.

### Primary use flows

| ID | Flow | Phase | Summary |
|----|------|-------|---------|
| F1 | Quick session log | 1 to 2 | Open app, start session at default gym, log each attempt in 5 taps or fewer (3 when the climb is already selected), set session RPE, end session. Target under 5 seconds per attempt at the wall. |
| F2 | Photo capture and hold tagging | 2 | Photograph the wall, pinch/pan on Skia canvas, tap to place holds, assign roles, link climbs to tagged holds. |
| F3 | Fall mapping and insight review | 2 | See fall_on_hold markers on the wall photo, fall distribution by hold role and position, flash/send/project/fail stats by grade. |
| F4 | Export, backup, restore | 1 | Automatic local backup on session end and app background; manual JSON and CSV export via share sheet; restore with schema version handling. |
| F5 | Grade translation | 3 | See a climb's grade in other schemes and a normalized difficulty built from rank_order and success rate across gyms. |
| F6 | AI-assisted tagging | 4 | Run on-device hold detection on a photo, accept/edit/reject bounding box prefill. Manual tagging always available and never blocked. |
| F7 | Video beta analysis | 5 | Capture or import a video, extract on-device pose metrics, view fall heatmap and beta comparison, raw video deleted per retention policy. |

## 2. Domain Model Anchors

| Entity | Key Fields |
|--------|------------|
| gym | id, name, is_archived |
| grade_scheme / grade_level | scheme id, ordered levels (built-in V-scale, Font; custom schemes allowed) |
| climb | id, gym_id, name, grade_scheme_id, grade_level_id, wall_angle_deg (nullable), board_angle_deg (nullable), is_active, is_archived |
| session | id, gym_id, started_at, ended_at (nullable = open), rpe (session-level, integer 1 to 10), notes |
| attempt | id, session_id, climb_id, attempt_no, outcome (enum: flash, send, project, fail), fall_on_hold_id (nullable), attempted_at, notes |
| photo / media | id, uri, width, height, capture metadata; working-resolution downscale (max 2048 px) |
| hold | id, photo_id, x, y (normalized 0..1), role (start, intermediate, top), color_family (nullable), source (manual/detection) |
| climb_hold | climb_id, hold_id, sequence (nullable beta order) |
| video | id, uri, duration_s, fps, size_bytes, retention state |
| schema_version | single-row migration tracker; forward-only migrations |

Constraints: attempts indexed on (climb_id) and (session_id); climbs indexed on (gym_id); attempt outcome is an enum, not a status column with a flash flag; RPE is session-level; fall_on_hold_id is per-attempt; migrations exist from day one.

## 3. User Stories with Acceptance Criteria

Priority legend: Must = MVP gate, Should = important, Could = nice.

### Phase 0: Spikes and technical validation

| ID | Story | Priority | Acceptance Criteria |
|----|-------|----------|-------------------|
| US-1 | Verify hold-detection model licensing so a store build can ship it | Must | 1. Apache-2.0 path confirmed (YOLOX-Nano or RF-DETR-Nano); Ultralytics AGPL path excluded; 2. License record in docs/decisions.md; 3. Fallback plan recorded (Phase 4 cancelled or Ultralytics Enterprise License purchased) |
| US-2 | Verify Kilter data position after roadmap cut | Must | 1. Determination recorded: no bundled catalog, no scraping, no unofficial API; 2. Board-generic schema fields preserved; 3. Re-entry path documented if written permission is ever obtained |
| US-3 | Benchmark on-device hold detection inference on target device | Must | 1. Benchmark harness runs >= 100 inferences on real photos; 2. p50 and p95 latency, peak memory, thermal state recorded against budget; 3. Pass/fail recorded in docs/research.md |
| US-4 | Benchmark pose estimation runtimes (fast-tflite MoveNet vs MediaPipe Tasks) with no Python bridge anywhere | Must | 1. Both options benchmarked or documented reason to skip; 2. fps and memory recorded; 3. Chosen stack recorded in docs/decisions.md |
| US-5 | Build a labeled hold-detection eval set from own gym photos | Must | 1. >= 200 photos, >= 1500 labeled hold instances, >= 3 walls, >= 2 lighting conditions; 2. 10% double-annotated with disagreement log; 3. 60/20/20 split by photo, test set frozen; 4. Baseline metrics computed and recorded |

### Phase 1: Core foundation

| ID | Story | Priority | Acceptance Criteria |
|----|-------|----------|-------------------|
| US-6 | Typed, tested Expo scaffold | Must | 1. `npx expo run:ios` boots on simulator and device; 2. npm test, tsc --noEmit (strict), lint pass; 3. AGENTS.md quick commands verified |
| US-7 | Data survives app upgrades | Must | 1. schema_migrations table with forward-only migrations from build one; 2. Automated test migrates empty and populated DBs; 3. Migration runs in a transaction, failure leaves prior schema intact; 4. Older app + newer DB refused with restore guidance |
| US-8 | Manage gyms | Must | 1. Create, rename, archive; 2. Session requires exactly one gym; 3. Duplicate names allowed, disambiguated by id; 4. Archived gym hidden from new sessions, visible in history |
| US-9 | Grade schemes (V-scale, Font, custom) | Must | 1. V-scale and Font built in; 2. Custom scheme = named ordered levels; 3. Grade stored as (scheme_id, level_id), never free string; 4. Deleting a scheme in use is blocked |
| US-10 | Manage climbs (name, grade, gym, angle, active/archived) | Must | 1. Create/edit/archive; 2. Angles nullable, 0 to 90 validated; 3. Archiving keeps all attempts; 4. Archived climbs hidden from quick-log, visible in history |
| US-11 | Log sessions with session-level RPE | Must | 1. Session has gym, date, start, optional end, RPE 1 to 10, notes; 2. At most one open session at a time, multiple per day allowed; 3. Closing idempotent; 4. Open session survives app kill |
| US-12 | Log attempts with outcome and fall-on-hold | Must | 1. Single enum outcome; 2. flash implies first-attempt send, enforced in domain layer; 3. fall_on_hold_id prompted on fail; 4. Attempt references climb and session; 5. Quick-log <= 5 taps (3 when the climb is already selected) and <= 5 s |
| US-13 | All data access through repositories | Must | 1. Repositories in src/data, entities in src/domain; 2. Lint rule or test fails if a screen imports the SQLite driver; 3. Repository unit tests per entity |
| US-14 | JSON and CSV export | Must | 1. JSON contains all entities and schema_version, round-trips losslessly in an automated test; 2. CSV per entity with stable columns; 3. Share sheet delivery; 4. Works with zero network |
| US-15 | Automatic backups | Must | 1. Backup on session close and app background (at most hourly); 2. Last 10 retained; 3. Restore replaces data atomically after confirmation; 4. 1000 sessions + 5000 attempts backed up in <= 5 s |
| US-16 | Import handles version mismatches | Must | 1. Newer schema_version rejected with plain-language message, no writes; 2. Older versions migrated then imported; 3. Corrupt files abort with zero writes; 4. Re-import idempotent by stable id |

### Phase 2: Photo capture and tagging MVP (MVP release gate)

| ID | Story | Priority | Acceptance Criteria |
|----|-------|----------|-------------------|
| US-17 | Capture a wall photo or pick from library | Must | 1. Camera and library sources; 2. Permission denied degrades to log-only mode with settings deep link; 3. HEIC/JPEG/PNG accepted; 4. Downscaled to 2048 px working resolution |
| US-18 | Smooth pinch/pan/zoom canvas | Must | 1. Skia canvas with pinch zoom, pan, double-tap reset; 2. Coordinates normalized 0..1, pixels only in UI layer; 3. >= 55 fps with 100 holds and a 2048 px image; 4. Tap placement error <= 3 px at 1x zoom |
| US-19 | Tag holds with roles (start/intermediate/top) | Must | 1. Role assigned at creation, editable; 2. Hold drag and delete; 3. Roles distinct by shape and color, colorblind-safe; 4. >= 200 tags per photo without layout corruption |
| US-20 | Link climbs to tagged holds | Must | 1. climb_hold mapping with optional beta sequence; 2. One photo per climb link; 3. Holds shareable across climbs; 4. Unlinking preserves holds and attempts |
| US-21 | Tag fall-on-hold per attempt on the canvas | Must | 1. Attempt editor shows the climb photo and holds; 2. Tap sets fall_on_hold_id; 3. Hold outside the climb's set rejected; 4. Clearing possible; 5. Completion <= 5 s including navigation |
| US-22 | Session history and detail | Must | 1. Reverse-chronological list with gym, date, RPE, attempt counts; 2. Detail groups attempts by climb with outcomes and fall holds; 3. Edit and delete with confirmation; 4. 1000 sessions scroll >= 55 fps |
| US-23 | Stats dashboard with fall heatmap | Must | 1. Flash/send/project/fail counts and rates by grade; 2. Heatmap on wall photo from fall data; 3. Fall distribution by hold role and position third; 4. Volume over time; 5. Renders <= 300 ms with 10k attempts |
| US-24 | Dark mode | Must | 1. System-follow plus manual override; 2. All Phase 2 screens themed, canvas contrast verified on dark photo; 3. Persisted across launches |
| US-25 | Settings screen | Must | 1. Default gym, default grade scheme, photo retention, video retention label, feature flags, export/backup entry points; 2. Changes persist immediately |
| US-26 | Fall data survives gym resets and re-grades | Must | 1. Re-grade recorded with effective date so historical stats state which grade was in effect; 2. Archive is the default reset workflow; 3. Deleting a climb with attempts blocked, archive-only |

### Phase 3: Cross-gym grade normalization (beta)

| ID | Story | Priority | Acceptance Criteria |
|----|-------|----------|-------------------|
| US-27 | Rasch-lite difficulty estimate per climb | Should | 1. Uses rank_order plus per-attempt success rate; 2. Pure function in src/domain with unit tests; 3. Incremental or memoized recompute; 4. Meets statistical thresholds on synthetic fixture |
| US-28 | Grade translator | Should | 1. Bidirectional mapping across built-in schemes; 2. Round-trip exact for mapped levels; 3. Custom schemes excluded with explanation |
| US-29 | Normalized difficulty in stats and attempt lists | Should | 1. Displayed alongside, never replacing, gym grade; 2. Legend explains the scale; 3. Charts switch raw vs normalized |
| US-30 | Data-sufficiency gate | Should | 1. Hidden until >= 30 attempts and >= 2 gyms; 2. Explanation shown below threshold, not blank; 3. Threshold configurable in advanced settings |

### Phase 4: On-device hold detection (Apache-2.0 self-trained)

| ID | Story | Priority | Acceptance Criteria |
|----|-------|----------|-------------------|
| US-31 | Detection prefills bounding boxes on a photo | Must | 1. Fully on-device, no network; 2. Boxes rendered as editable suggestions with confidence; 3. Meets quality and perf budgets (section 6); 4. Cancel anytime, 5 s timeout falls back to manual |
| US-32 | Accept, edit, or reject suggestions | Must | 1. Bulk accept, per-box edit/delete, undo; 2. Manual tagging works with model disabled, missing, or failed (tested); 3. No UI path requires AI output to proceed |
| US-33 | Optional color-family suggestions | Could | 1. Chip on hold editor, default off; 2. Below 0.80 top-1 accuracy ships hidden behind dev flag; 3. Never affects position or role without confirmation |
| US-34 | Model licensing and attribution handled | Must | 1. Apache-2.0 model license documented; 2. Dataset attributions (climbtag, blackcreed, and pwals, all CC BY 4.0, plus own photos) in settings/about; 3. Feature behind flag, off by default until quality gates pass |
| US-35 | Detection disables on unsupported or overheating devices | Must | 1. Capability check at startup (iOS 16 + benchmark result); 2. Auto-disable on repeated failure or thermal pressure with settings notice; 3. Peak memory delta within budget or feature refuses to run |

### Phase 5: BoulderVision video analysis (exploratory, feature-flagged)

Note: former Phase 5 Kilter integration was cut 2026-10-19 (Kilter Terms prohibit automated access; Aurora API dead).

| ID | Story | Priority | Acceptance Criteria |
|----|-------|----------|-------------------|
| US-36 | Capture or import video with retention enforcement | Could | 1. Duration/fps/size stored at import; 2. Default retention "delete raw after metrics extraction", options 7/30 days; 3. Cache warns at 1 GB, prompts at 2 GB; 4. Deleting raw keeps extracted metrics |
| US-37 | On-device pose estimation | Could | 1. Runtime from US-4 spike, fully on device; 2. No person / multiple people handled per edge cases; 3. Meets pose budgets; 4. Processing cancellable and resumable |
| US-38 | Relative velocity and displacement metrics | Could | 1. Metrics normalized (body-height units, frame-relative), labeled relative not absolute; 2. Per-attempt summary stored; 3. Meets error budgets |
| US-39 | Fall heatmaps and beta sequence comparison | Could | 1. Fall events derived from pose plus hold geometry; 2. Side-by-side comparison of two attempts on the same climb; 3. Renders <= 500 ms |
| US-40 | Whole feature behind experimental flag | Could | 1. Off by default; 2. Explicit experimental labeling and one-tap disable; 3. Crash or budget breach auto-disables and logs locally |

### Deferred stories (former Kilter phase, kept for possible re-entry)

US-36 to US-40 of the original PM draft (board-provider abstraction, offline catalog, board explorer, board attempt logging, store licensing gate) are deferred with the roadmap cut. Board-generic schema fields (boards, board_problems tables, board_angle_deg) are retained in schema so the feature can return without a migration overhaul.

## 4. Per-Phase Definition of Done

| Phase | Definition of Done |
|-------|-------------------|
| 0 | Five spikes complete with reports in docs/research.md and decisions in docs/decisions.md; license determinations recorded as go/no-go; perf benchmarks measured on iPhone 11/12 class hardware with pass/fail vs budget; eval set built, split, frozen, baseline metrics recorded; written go/no-go for Phase 1 and updated risk register. |
| 1 | Scaffold runs on simulator and device; tsc strict, jest, lint pass; schema and migrations land with populated-DB migration test; all CRUD through repositories only; JSON export round-trips; CSV export produced; backup and restore demonstrated end to end; import version-mismatch tests pass; quick-log latency budget met. |
| 2 | All Phase 2 stories accepted; 3 real gym sessions dogfooded with zero data loss and no crash; canvas frame budget met on device; airplane-mode full regression passes; zero network calls observed through a proxy for F1 to F4; dark mode verified; tester checklist green. MVP SHIP GATE. |
| 3 | Normalization meets statistical thresholds on synthetic fixture; translator round-trip test passes; data-sufficiency gate works; dogfooded on real multi-gym data for 2 weeks. |
| 4 | Detection meets all quality and perf budgets on the frozen test split; Apache-2.0 license and dataset attributions cleared (US-1, US-34); "AI never blocks manual tagging" test suite passes (model missing, crashed, timeout, zero detections); attribution and flags in place. |
| 5 | Pose pipeline meets budgets; retention policy enforced by tests; fall heatmap and beta comparison accepted; experimental flag off by default with auto-disable proven; if any budget misses, feature stays flagged off and phase is marked not shipped rather than degraded. |

## 5. Edge Cases

| Case | Expected Behavior |
|------|-------------------|
| Fully offline (airplane mode) | Every flow works. Phase 2 gate verifies zero network calls through a proxy for F1 to F4. Network never required, never prompted. |
| Device storage full | Attempt logging still works (tiny DB writes); capture shows a clear message; backup failure shows a persistent warning badge, retried on next foreground. |
| Camera permission denied | Log-only mode with settings deep link; no re-prompt loops; library path remains if granted. |
| Photo library limited access (iOS) | Camera path remains; message explains partial access and offers select-more-photos. |
| Import from newer schema version | Rejected before any write with plain-language message; nothing changes. |
| Import corrupt or truncated JSON | Atomic abort, zero writes, specific error (missing entity, bad enum, bad date). |
| Duplicate import | Idempotent upsert by stable id; no duplicates; counts reported after import. |
| Gym reset | User archives affected climbs (workflow surfaced in UI), creates new climbs on a fresh photo; old attempts and stats preserved on archived climbs. |
| Delete climb with attempts | Blocked; archive-only path with explanation. |
| fall_on_hold_id references another climb's hold | Rejected at domain layer with a test; UI prevents it; import rejects the file. |
| Outcome contradiction (send with fall hold) | Domain validation warns; flash/send record fall hold as null by rule; project/fail prompt for it. |
| RPE out of range | UI restricts to integer 1 to 10; domain rejects invalid values regardless of source. |
| App killed mid-session | Session remains open and resumable; each attempt is a committed row at log time. |
| Timezone change / DST / edited date | Timestamps stored UTC plus local date at creation; stats bucket by local date; editing re-buckets without touching attempts. |
| Huge photo (48 MP HEIC, panorama) | Downscaled to 2048 px working resolution; normalized coordinates remain valid; warn above 30 MB. |
| Photo edited after holds tagged | Destructive crop of tagged photos blocked in v1. |
| Hold detection returns zero holds / runtime error / model missing | Silent fallback to manual tagging with dismissible notice; never a blocker; error logged locally. |
| Thermal throttling during detection | Detection pauses with cooldown notice; manual tagging unaffected. |
| Pose: no person or multiple people | No person: metrics unavailable with reason. Multiple people: user selects subject or largest skeleton proposed for confirmation. Never guess silently. |
| Video storage growth | Retention default deletes raw after extraction; cache warning at 1 GB, prompt at 2 GB; per-video delete always available. |
| Migration failure mid-migration | Transaction rolls back; prior schema intact; app offers restore-from-backup; never half-migrated. |
| Restore onto older app build | Refused with guidance (update first), no writes. |
| Low-end device below floor (older than iPhone 11) | Unsupported; core features target iPhone 11 and newer only. iPhone 11 with AI failing benchmarks gets AI auto-disabled via capability check. |
| Duplicate gym names | Both allowed, disambiguated by id and creation date in pickers. |
| Re-grade after attempts exist | Grade change recorded with effective date; historical stats state which grade was in effect. |
| Locale and non-English grade names | Grades are scheme-defined identifiers, not localized strings; dates/numbers localized; v1 UI English only. |
| Low Power Mode | Canvas and detection throttle gracefully; logging latency unaffected. |
| Interruption during photo capture | Partial capture discarded; no orphan media rows (reconciliation sweep on launch). |

## 6. Numeric Acceptance Criteria

### Phase 0: Eval set construction
- >= 200 photos, >= 1500 labeled hold instances, >= 3 distinct walls, >= 2 lighting conditions, from own gym photos.
- 10% double-annotated; inter-annotator disagreement on hold presence <= 5%, on role <= 10%.
- Split 60/20/20 train/val/test by photo; test set frozen before Phase 4 training.

### Phase 4: Hold detection quality (frozen test split)
- Precision >= 0.85 and recall >= 0.80 at IoU >= 0.5, at an operating threshold chosen on the val set.
- mAP@0.5 >= 0.75.
- Median per-image absolute hold-count error <= 1.0 hold.
- False positives <= 0.5 per image at operating threshold.
- Color-family classification (optional): top-1 accuracy >= 0.80; below threshold ship hidden behind dev flag.

**Status (D1, 2026-10-21, the single frozen test run).** Precision 0.9509,
recall 0.8788, and mAP@0.5 0.9130 pass. Median absolute hold-count error is 1.0
and passes at the boundary. False positives are 1.8832 per image and fail the
0.5 limit. RF-DETR-Nano is 109.2 MB float32 and about 29 MB at int8, so the
15 MB deployment budget cannot be met at 28.9M parameters; YOLOX-Nano meets the
size budget but fails recall at every threshold. No Phase 4 model is shippable
under this section yet, and the decision is recorded in docs/decisions.md.

**Status (Core ML, 2026-10-21).** The RF-DETR conversion is real: an iOS16
mlprogram package passes decision-space parity against ONNX at float32 (8.31e-4
score, 8.79e-7 box) and runs warm in 41 to 50 ms on the M5. Compression does not
hold: float16 51.6 MB, int8 26 MB, and int4 13 MB all fail parity, so the
parity-clean package is 104.4 MB and the 15 MB budget is still unmet. Device
latency, memory, thermals, and cold load remain unmeasured.

### Phase 4: Inference performance and thermals (iPhone 11 / A13 class minimum)
- Model: YOLOX-Nano or RF-DETR-Nano, int8 quantized, <= 15 MB bundled; cold model load <= 2 s.
- Latency: p50 <= 500 ms, p95 <= 1500 ms per photo (2048 px working resolution).
- Memory: peak delta <= 300 MB during inference.
- Thermals: 20 consecutive detections without serious thermal pressure; on breach, cooldown behavior per edge cases.
- Battery: 50 consecutive detections drain <= 5% on a healthy battery.
- Hard ceiling: any single inference exceeding 5 s is cancelled and falls back to manual.

### Phase 3: Grade normalization
- Synthetic fixture (5 gyms x 40 climbs x 100 attempts with injected latent difficulties): Spearman rank correlation between recovered and true difficulty >= 0.90.
- Translator round-trip exact for mapped levels; unmapped levels return null, never a guess.
- After 100 additional random attempts, established climbs move <= 0.1 grade unit.
- Data sufficiency gate: >= 30 attempts and >= 2 gyms before the feature surfaces.

### Phase 5: Pose and metrics
- Subject found with keypoints in >= 95% of eval frames where a person is visible.
- Static-clip keypoint jitter <= 0.02 body-heights after smoothing.
- Relative velocity/displacement median error <= 15% vs manually annotated synthetic clips; labeled and exported as relative units.
- Fall event detection F1 >= 0.80 on labeled eval clips (>= 30 clips, >= 10 falls).
- Throughput: 720p offline extraction of a 30 s clip <= 60 s; processing >= 10 fps sustained.
- Memory: peak <= 500 MB; cache warning at 1 GB, prompt at 2 GB; raw video deleted per retention default.

### Cross-cutting app budgets (gates at Phase 2)
- Cold start to interactive <= 2.5 s on the floor device.
- Quick-log an attempt <= 5 s and <= 5 taps (3 when the climb is already selected).
- Stats dashboard render <= 300 ms with 10k attempts (DB query <= 100 ms).
- Canvas >= 55 fps pan/zoom with 100 holds on a 2048 px image.
- Backup of 1000 sessions + 5000 attempts <= 5 s; restore <= 15 s.
- Storage: 100k attempts <= 50 MB excluding media.
- Zero network calls in F1 to F4 (proxy-verified), any phase.

## 7. Scope Boundaries for v1

### IN (v1 = Phases 0, 1, 2)
- Everything in Phases 0 to 2: scaffold, schema + migrations, gym/grade/climb/session/attempt logbook, photo capture, Skia canvas tagging, role tagging, per-attempt fall-on-hold tagging, session history, stats dashboard with fall heatmap, dark mode, settings.
- JSON export/import (full fidelity), CSV export, automatic local backup + restore, version-safe import.
- Hard offline operation of every v1 feature; zero accounts; zero network; single profile (profile_id-ready schema).
- iPhone (iOS 16+), English, V-scale + Font + custom grade schemes.

### OUT (never or explicitly not v1)
- Accounts, authentication, cloud sync, any server component.
- Social features: sharing, feeds, friends, leaderboards, competitions.
- Web app, Android (post-v1), iPad-optimized layouts, watch app.
- AR route reading, route-setting tools, coaching content.
- Python bridge of any kind (unshippable on iOS; banned by architecture).
- Kilter catalog bundling, scraping, or unofficial API access (roadmap cut 2026-10-19).
- Ultralytics-trained model weights (AGPL; roadmap cut 2026-10-19).
- CSV import (CSV is export-only; full-fidelity import is JSON).
- Widgets, Live Activity, Lock Screen.
- Telemetry, analytics, crash reporting that transmits data (local logs only).

### DEFERRED (roadmap, not v1)
- Phase 3 grade normalization and translator.
- Phase 4 on-device hold detection (license-cleared self-trained model).
- Phase 5 BoulderVision (feature-flagged, experimental).
- Kilter or other board integration (cut; possible re-entry with written permission).
- Android port (after iOS v1 is stable).
- Multi-profile (schema stays profile_id-ready).
- iCloud Drive auto-backup folder (opt-in fast follow).
- HealthKit workout export (low value for bouldering, default no).
- Widgets and watch app.

## 8. Priority Summary

| Feature | Priority | Rationale |
|---------|----------|-----------|
| Schema + migrations + repositories (US-7, US-13) | MVP | Data safety is the product promise; retrofitting migrations is how local-first apps lose users. |
| Session/attempt logbook (US-11, US-12) | MVP | Core value: what I climbed and where I fell. |
| Photo tagging + fall-on-hold (US-17 to US-21) | MVP | The differentiator; the reason this app exists over a notes app. |
| Stats dashboard + heatmap (US-23) | MVP | Insight closes the loop; without it logging is a chore. |
| Export/import/backup (US-14 to US-16) | MVP | Zero-account local-first means the user owns the only copy. |
| Dark mode, settings (US-24, US-25) | MVP | Gym lighting; explicit in approved v1 scope. |
| Grade normalization (Phase 3) | Next | High value for multi-gym climbers, needs data accumulation. |
| AI hold detection (Phase 4) | Next | Tagging accelerator; never on the critical path. |
| BoulderVision (Phase 5) | Exploratory | Research-grade; ships only if budgets pass, always flagged experimental. |

## 9. Open Questions Resolved

| # | Question | Resolution |
|---|----------|------------|
| 1 | Multi-profile in v1? | Single profile, schema stays profile_id-ready (accepted default) |
| 2 | Backup destination? | App-local rotation (last 10) + manual export; iCloud Drive opt-in fast follow (accepted default) |
| 3 | ML thresholds accepted? | Yes, accepted as written |
| 4 | Default grade scheme? | V-scale primary, Font switchable (accepted default) |
| 5 | Device and OS floor? | iOS 16, iPhone 11 and newer (user decision) |
| 6 | App Store goal? | Yes, eventual hard goal (user decision) |
| 7 | HealthKit export? | Deferred, not built (accepted default) |
| 8 | Original photo retention? | Keep originals by default, setting to discard (accepted default) |
| 9 | Kilter Phase 5? | Cut from roadmap (user decision) |
| 10 | Model path? | Apache-2.0 self-trained (user decision) |
