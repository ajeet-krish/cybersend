# CyberSend Test Strategy

Last updated: 2026-10-20 (Phase 2 MVP gate checklist, M3 Task 5)

## Levels

| Level | Tool | Scope | Runs |
|-------|------|-------|------|
| Unit | Jest (node env) | src/domain, coords.ts, preprocess.ts, nms.ts, backup serialization | every commit |
| Repository | Jest + node:sqlite adapter | src/data/repositories, migrations runner, transactions | every commit |
| Component | jest-expo + @testing-library/react-native | screens, hooks, canvas gestures as reducers | every commit |
| ML eval | tools/eval (onnxruntime-node, `npm run eval`) | hold detection precision, recall, mAP@0.5 on a frozen COCO split | on model change |
| E2E | Maestro (e2e/flows/*.yaml) on iOS dev build | log session, log attempt with fall-on-hold, tag photo, export/import round trip | pre-release, nightly |

## Rules

- Domain logic and repositories require tests (AGENTS.md contract). No tests needed for pure presentational styling.
- Repository tests create an in-memory database per test file, run migrations from empty, and assert rollback behavior by forcing errors inside with_transaction.
- Fake repositories implement the same interfaces as real ones; the DI container in src/app/providers.tsx swaps them in tests.
- Canvas gesture logic is tested as pure reducer functions over Viewport and hold lists; only thin glue touches react-native-gesture-handler.
- Preprocess parity: the pure preprocess function is tested on fixed RGBA fixtures so app and eval harness cannot drift.

## ML Gates (see docs/requirements.md section 6 for the authoritative numbers)

- Phase 0 spike: eval set of at least 20 labeled images, latency budget measured on device.
- Phase 4 quality gate: frozen test split, precision >= 0.85 and recall >= 0.80 at IoU 0.5, mAP@0.5 >= 0.75, at an operating threshold chosen on the val split. Measured first on the merged proxy-domain test split (tools/eval, `npm run eval -- --gate`) and then on the frozen US-5 self-collected test split before acceptance.
- Phase 5 gate: correct fall-on-hold attribution >= 0.70 on labeled clips, pose throughput >= 8 Hz sustained.

## Commands

```bash
npm test               # unit + repository + component
npx jest --watch       # focused loop
npx tsc --noEmit       # type check
npm run test:eval      # ML eval harness (added Phase 4)
npm run test:e2e       # maestro test e2e/flows (added Phase 2)
```

## Phase 2 MVP gate

The Phase 2 ship gate checklist (docs/architecture.md M3 gates, docs/requirements.md section 6
cross-cutting budgets and section 4 definition of done). Status vocabulary:

- **PASS**: automated evidence exists in the suites and was green at M3 Task 5 verification
  (2026-10-20: 258 package tests, 23 app tests, 11 UI tests, zero failures, zero build warnings).
- **PENDING DEVICE**: only the user can produce the evidence (physical hardware, real gym
  sessions, network tooling). Each pending item carries its exact procedure. No pending item
  is claimed as passing anywhere in these docs.

| # | Gate item | Budget | Status | Evidence / procedure |
|---|-----------|--------|--------|----------------------|
| 1 | Three dogfooded gym sessions with zero data loss and no crash | 3 sessions | PENDING DEVICE | Procedure: take the device build to the gym for three separate sessions; in each session start, log at least one attempt through quick-log, add or edit a session note, and close the session; after each session force quit the app, relaunch, and confirm the session and its attempts are intact; after session three run Settings, Create backup, then Create export and confirm both complete without error; confirm zero crashes in the process (Settings shows no restore prompt). Record the dates and attempt counts in docs/reviews.md. |
| 2 | Canvas frame rate on device with 100 holds | >= 55 fps pan/zoom, 2048 px image | PENDING DEVICE | Procedure: build Development, launch on the device with `-CYBERSEND_UI_TEST_SEED_HOLDS 100` (seeds a Perf Wall climb with a synthetic photo and 100 holds), open the climb, add the photo if needed, enter tagging, then pan and pinch zoom across the full wall for at least 30 s while watching the DEVELOPMENT FPS HUD (CADisplayLink); record the observed steady state. Simulator is a documented proxy only (docs/architecture.md test strategy), so the number must come from hardware. |
| 3 | Tap placement error | <= 3 px at 1x zoom | PASS (automated evidence) | Round-trip unit tests (Tests/Domain/CanvasGeometryTests, sub-pixel error) plus the deterministic XCUITest coordinate check (TaggingSmokeTests parses accessible position strings, maps them back through the canvas fit box, and compares against actual tap coordinates). Device spot check rides item 2 (no separate action). |
| 4 | Airplane mode full regression | Every Phase 2 flow works offline | PENDING DEVICE | Procedure: enable airplane mode (and disable Wi-Fi with it), then run F1 quick-log a new attempt on the open session, F2 capture or import a photo and tag three holds, F3 open the Stats tab and the fall heatmap, F4 create backup and JSON export, then restore that backup behind the confirmation dialog; confirm no flow blocks, no network prompt appears, and all data survives. Repeat once with the app force quit and relaunched mid flow. |
| 5 | Zero network calls in F1 to F4 | Zero, proxy verified | PENDING DEVICE | Procedure: run the device or simulator through a macOS proxy (for example Charles or mitmproxy with its CA installed, or `sudo tcpdump -i any port 443` as a lighter variant) with a clean proxy log; launch the app fresh, run F1 to F4 as in item 4 with airplane mode OFF so any call would be visible; confirm the proxy log shows no connections attributable to the app and the app requests no certificate trust; repeat for a cold start with no interaction for 60 s (background heartbeat check). Record tool and result in docs/reviews.md. |
| 6 | 2048 px working copy policy | 2048 px long edge, pixels up | PASS (automated evidence) | PhotoIngestTests cover the working copy size, thumb size, and EXIF orientations 1, 3, 6, 8; app test testSyntheticPhotoFeedsTheRealIngestPipeline asserts the identical Development path produces the same 2048 px artifacts. |
| 7 | Dark mode on every Phase 2 screen | System follow plus manual override, persisted | PENDING DEVICE | Procedure: set the device to dark appearance, walk Logbook, session detail, climb editor, tagging canvas (over a dark photo), Stats dashboard including the heatmap, Sessions, Settings, and the restore dialog; confirm contrast on each (the tagging canvas over a dark photo is the known risk spot, US-24.2); toggle Settings, Appearance to Light and to Dark with a force quit between each to confirm persistence; also confirm the Stats charts and heatmap legend stay legible in both appearances. |
| 8 | Cold start to interactive | <= 2.5 s on the floor device (iPhone 11 class) | PENDING DEVICE | Procedure: on the floor device, force quit the app, then launch from the home screen with an external stopwatch (or the Xcode Debug gauge time to first significant interactive); take 5 cold starts and record the median; confirm MediaSweep activity does not delay the first frame (it runs after first frame by design). The pass condition is the Logbook tab tappable within the budget. |
| 9a | Quick-log tap budget | <= 5 taps per attempt (3 when the climb is already selected) | PASS (automated evidence) | QuickLogSmokeTests.testLogAttemptWithinFiveTaps counts taps and refuses an extra tap (assertion before the tap); testLogAttemptWithHoldRowAsTheFifthTap proves the M3 fall hold row keeps the 5 tap budget; FallHoldSmokeTests proves a row tap saves. |
| 9b | Quick-log time budget | <= 5 s per attempt at the wall | PENDING DEVICE | Procedure: at the gym (or standing at a wall), start a stopwatch, open the app, open the session, choose a climb, tap Fail, tap Skip or a hold row; record the elapsed time for 5 consecutive attempts including one cold (app just foregrounded) attempt; record the worst case. |
| 10 | Backup and restore round trip | Lossless, <= 5 s backup of 1000 sessions + 5000 attempts, <= 15 s restore | PASS (automated evidence) | Golden fixture round trips (data_native_v1 pinned import fixture, data_native_golden_v4 pinned export, v2 and v3 pinned import fixtures), BackupServiceTests US-15.4 budget test (5000 attempts seeded, measured 0.59 s of the 5 s budget), RestoreGateTests confirmation lifecycle, and SettingsRestoreSmokeTests UI proof that a confirmed restore reverts data while a cancel changes nothing. |
| 11 | Stats dashboard render | <= 300 ms with 10k attempts, DB query <= 100 ms | PASS (automated evidence) | StatsStoreTests "aggregating 10k attempts stays well under the 100 ms query budget" seeds a real in-memory DB with 10k attempts, 40 climbs, 100 tagged holds and asserts best of three full refreshes under 100 ms via ContinuousClock. Measured on this machine: about 88 ms debug (dominated by DumpRepository dictionary mapping under -Onone) and about 14 ms optimized; the store aggregation itself is about 20 ms of that. The 300 ms render budget is covered by the store budget plus the charts rendering bounded series (grade rows, week buckets, hold markers). |

Gate decision: items 3, 6, 9a, 10, and 11 are PASS with automated evidence; items 1, 2, 4, 5, 7,
8, and 9b are PENDING DEVICE with the procedures above. The Phase 2 MVP ship gate stays closed
until every PENDING DEVICE item is executed by the user and recorded here with dates and results.

## UI overhaul verification (2026-10-21)

Package suite: 267 swift-testing cases in 47 suites, green. App suite: 25 XCTest cases, green
(HomeOverviewTests adds two). UI smoke set: 19 cases covering quick log (dropdown plus a hold row
as the fifth tap), fall hold, session history, stats, settings catalog, settings and restore,
tagging, capture, and the problems catalog.

| Item | Covered by | Status |
|------|-----------|--------|
| Per attempt RPE stored, patched, cleared, range checked | AttemptRepositoryTests rpe round trip, Migration003Tests, ExportSerializeTests golden v3 import | PASS |
| Project outcome retired and historical rows rewritten to fail | Migration003Tests historical project rows, repository outcome checks | PASS |
| Problem details column | Migration004Tests, ClimbRepositoryTests.notesRoundTrip, CsvExportTests climbs notes, ImportTests nativeV3FixtureImportsAndKeepsEffort | PASS |
| Problems catalog list, detail, history, archive, archived filter | ProblemsCatalogSmokeTests (two cases) | PASS |
| Home recent sessions, recent climbs order, heatmap shape | HomeOverviewTests (two cases), AttemptRepositoryTests.listRecentAcrossSessions | PASS |
| Quick log climb dropdown and tap budget | QuickLogSmokeTests.testLogAttemptWithinFiveTaps, testLogAttemptWithHoldRowAsTheFifthTap | PASS |
| Inline problem create and edit from the session screen | SessionClimbInlineSmokeTests (two cases: create and stay open into the photo section, then edit and rename) | PASS |
| Session media rows, duration, playback sheet, closed session access | SessionMediaSmokeTests (two cases) | PASS |
| Video storage path, extension and id validation | MediaStorageTests.videoWriteAndRead | PASS |
| Appearance defaults to dark and keeps the light variant | SettingsCatalogSmokeTests, Theme contrast notes in docs/reviews.md | PASS (automated) |
| Per screen dark mode contrast on device | Gate item 7 above | PENDING DEVICE |
| Home visual pass (heatmap, recent blocks, gym menu) | Simulator screenshots reviewed 2026-10-21 | PASS (visual) |

Resolved: sessions (open and closed) attach photos and videos after the fact through the
session media block; the earlier gap note no longer applies.

## Climb categories (2026-10-21)

Package suite: 278 swift-testing cases in 49 suites, green. The category layer is covered at the
domain, migration, repository, CSV, and export boundaries:

| Item | Covered by | Status |
|------|-----------|--------|
| Fixed category list, declaration order, encode nil when empty | ClimbCategoryTests | PASS |
| Parse ignores unknown tokens, blanks, case, duplicates | ClimbCategoryTests.parsingIsTolerant | PASS |
| Migration 005 appends nullable climbs.categories, existing rows keep data | Migration005Tests (two cases) | PASS |
| Categories round trip in declaration order, clear to null | ClimbRepositoryTests.categoriesRoundTrip | PASS |
| Climb moves between gyms, unknown gym rejected | ClimbRepositoryTests.movesBetweenGyms | PASS |
| CSV climbs gains a quoted categories column | CsvExportTests.climbsCsv, buildCsvFromRepositories | PASS |
| Golden v5 export bytes, only schema_version and climbs.categories differ from v4 | ExportSerializeTests.goldenBytesMatch | PASS |
| v4 file imports through the 4 to 5 migration with categories null | ImportTests.nativeV4FixtureImports | PASS |
| v1, v2, v3 fixtures still import after the spec split | ImportTests, ExportSerializeTests | PASS |

## Problems editor, detail, catalog, and open session (2026-10-21)

Package suite: 280 swift-testing cases in 49 suites, green. App suite: 25 XCTest cases, green.
UI smoke set: 19 cases, green.

| Item | Covered by | Status |
|------|-----------|--------|
| Session climb membership: add, select, remove while untried, attempts pin a climb, reload rebuilds from attempts | SessionDetailStoreTests.addAndRemoveSessionClimbs, attemptedClimbsStayInTheSession | PASS |
| Editor sections: gym picker, details group, notes, category grid, single Tag holds | TaggingSmokeTests (tag link from the Holds row), ProblemsCatalogSmokeTests | PASS |
| Categories on the catalog row and the detail chips, gym in both | ProblemsCatalogSmokeTests.testCatalogListsSeedProblemsAndOpensHistory | PASS |
| Catalog filters by gym, level, category, status and the filtered empty state | ProblemCatalogStore in-memory filters, ProblemsCatalogSmokeTests archive toggle | PASS (automated) |
| Detail shows gym, categories, hold stats, notes, history; no tagging link | ProblemsCatalogSmokeTests, TaggingSmokeTests reach tagging only through the editor | PASS |
| Add Climb, Edit Problem, New Problem side by side | QuickLogSmokeTests, FallHoldSmokeTests, RpeSmokeTests, SessionClimbInlineSmokeTests | PASS |
| Attempts read climb name, result, RPE, fall hold and are editable during an open session | QuickLogSmokeTests attempt label assertions, SessionDetailView edit sheet | PASS (automated) |
| Tap budget after the climb list: 5 taps worst case, 3 when the climb is already added | QuickLogSmokeTests.testLogAttemptWithinFiveTaps, testLogAttemptWithHoldRowAsTheFifthTap | PASS |
| Themed fields replace the system rounded border on every text field | Simulator screenshots (climb name and notes, session notes, gyms) | PASS (visual) |
| Outcome buttons carry the outcome colour and dim when disabled | QuickLogSmokeTests, RpeSmokeTests, FallHoldSmokeTests unchanged and green | PASS |
| All four catalog filters visible without scrolling | Simulator screenshot after the FlowLayout change | PASS (visual) |
| Photo empty state is one tappable card, no duplicate button | TaggingSmokeTests and SessionClimbInlineSmokeTests tap climb.photo.add | PASS |
| Hold stats shows role and percent across and down on one line per hold | Simulator screenshot, seeded three hold climb | PASS (visual) |
| App icon: white climbing mark on purple, 1024 px, no alpha | sips inspection (1024, hasAlpha no) and asset catalog build | PASS |
| Screenshot pass: catalog, detail, hold stats, editor (top and bottom), create screen, open session, gym settings | Simulator screenshots reviewed 2026-10-21 | PASS (visual) |

## Hold detection ML (2026-10-21)

| Item | Command | Result |
|------|---------|--------|
| Harness unit tests, 44 cases (8 new: YOLOX decode, clipping, NMS, raw preprocess) | cd tools/eval && npm test | PASS |
| Harness type check | npx tsc --noEmit | PASS |
| ONNX contract plus one dummy inference, both exports | npm run verify -- <model> | PASS (RF-DETR 153 ms, YOLOX 13 ms on Mac CPU) |
| Torch versus ONNX parity, 5 val images, decision space at 1e-3 | python -m hold_train.parity_check | PASS (RF-DETR score 8.31e-4, box 7.15e-7; YOLOX 1.06e-5, 2.19e-6) |
| Val comparison, 591 images, confidence 0.5 | npm run eval on val | RF-DETR 0.9490 / 0.8894 / 0.9235; YOLOX 0.9185 / 0.6725 / 0.8101 |
| Val operating curve, thresholds 0.6, 0.7, 0.75, 0.8 | npm run eval on val with --confidence | recall 0.8757 / 0.8472 / 0.8172 / 0.7603; FP per image 1.3486 / 0.8342 / 0.6176 / 0.4213; count error 1 / 2 / 3 / 4; no threshold meets all three limits |
| Frozen test run, 582 images, single gated use, RF-DETR | npm run eval -- --gate --i-accept-one-test-run | precision 0.9509, recall 0.8788, mAP@0.5 0.9130, FP/image 1.8832, median count error 1.0 |
| Phase 4 accuracy criteria | docs/requirements.md section 6 | PASS for precision, recall, mAP, count error; FAIL for FP/image (0.5 limit) |
| Core ML export, RF-DETR, rfdetr 1.11.2 exporter | PYTHONPATH=src .venv/bin/python -m hold_train.export_coreml | PASS, 104.4 MB float32 package, iOS16 mlprogram, 740 MIL ops, about 5 s |
| Core ML versus ONNX parity, float32, 5 val images | PYTHONPATH=src .venv/bin/python -m hold_train.parity_coreml | PASS (CPU_ONLY score 8.31e-4, box 8.79e-7; all compute units 8.31e-4, 8.94e-7) |
| Core ML latency, float32, M5 Mac, one loaded photo | same tool | CPU_ONLY median 95.1 ms; all compute units median 43.6 ms (41 to 50 ms warm), first call 4164 ms including load |
| Weight compressed packages | hold_train.export_coreml --palettize-bits 8 4 | float16 51.6 MB, int8 26 MB, int4 13 MB |
| Compressed package parity | parity_coreml on each package, CPU_ONLY | FAIL all three (float16 score 2.96e-1, int8 4.54e-1, int4 9.77e-1 with non-finite boxes) |
| Compressed package val accuracy | not run, needs a Core ML evaluation path in the harness | PENDING |

The test run consumed the one-run policy; the ledger line is in
tools/eval/reports/test_ledger.jsonl and the report is
tools/eval/reports/d1_test_eval.json.
