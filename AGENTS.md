# CyberSend

Local-first bouldering and climbing tracker for iOS. Native Swift app (SwiftUI plus UIKit gestures, GRDB/SQLite, Core ML), zero accounts, no cloud dependency for core features. iOS only, forever. The TypeScript tree (src/ and app/) is the frozen port spec for the native migration.

## Quick Commands

TypeScript tooling is verified against the scaffold (ef63924). Native commands are verified on Xcode 26.6 with the iOS 26.5 simulator (iPhone 17 Pro). npm manages tools/; the Swift package resolves locally through Xcode. Details live in tools/eval/README.md and tools/train/README.md.

```bash
# native iOS track (Xcode 26.6 active, iOS 26.5 simulator verified)
cd ios && swift build
cd ios && swift test
xcodebuild -project ios/CyberSend.xcodeproj -scheme CyberSend -sdk iphonesimulator build

# frozen TypeScript port spec
npm test                # jest suite
npx tsc --noEmit        # type check
npx expo lint           # lint

# ML tooling (each in its own directory)
cd tools/eval && npm install && npm test   # harness unit tests, no model needed
cd tools/eval && npm run eval:stub         # stub eval run, writes reports/stub_eval.json
cd tools/train && uv sync                  # training venv from uv.lock
cd tools/train && uv run hold-build        # rebuild merged dataset, deterministic
```

Training runs (hold-train-d1, YOLOX comparison, hold-train-smoke) require explicit user approval before execution. See the warning in tools/train/README.md.

## Conventions

- TypeScript strict mode. No implicit any, no unused locals, no unchecked index access. (frozen port spec)
- Swift follows the Swift API Design Guidelines. 4-space indent (spaces, not tabs), camelCase locals and parameters, PascalCase types. The snake_case rule does not apply to Swift.
- snake_case for local variables and function parameters in TypeScript. camelCase for exports and types.
- No em dashes, double hyphens, or dash equivalents in code, comments, or docs. Use full punctuation.
- All data access goes through repositories. Views and screens never call SQLite or GRDB directly.
- Canvas and vision coordinates are normalized (0..1) at the boundary. Convert to pixels only in UI layers.
- Local first: every feature must work offline. Sync and network paths are optional.
- Tests required for domain logic and repositories.

## Project Map

```
ios/                 native app (the active track since 2026-10-19)
  Sources/Domain/    entities, grade normalization, pure logic
  Sources/Data/      GRDB schema, migrations, repositories, backup
  Sources/Features/  sessions, photos, tagging, ML, flags
  Sources/UI/        theme, canvas, shared SwiftUI views
  Tests/             swift-testing suites, in-memory GRDB
src/                 TypeScript port spec, frozen (behavior reference)
app/                 Expo routes, part of the frozen port spec
assets/models/       ONNX canonical artifacts plus Core ML deployment copies
tools/eval/          ML eval harness (unchanged)
tools/train/         training and dataset pipeline (unchanged)
docs/                architecture, decisions, research, reviews, tests
```

## Status

ML phases (requirements numbering), unchanged:

| Phase | Description | Status |
|-------|-------------|--------|
| 0 | Spikes and technical validation | In Progress |
| 1 | Core foundation | Not Started |
| 2 | Photo capture and tagging MVP | Not Started |
| 3 | Grade normalization | Not Started |
| 4 | AI hold detection (Apache-2.0 self-trained) | In Progress (accuracy decided 2026-10-21 on the single frozen test run: RF-DETR-Nano 0.9509 precision, 0.8788 recall, 0.9130 mAP@0.5; no val threshold meets FP<=0.5, recall>=0.80, and count error<=1.0 together, the closest point is about confidence 0.765 at recall 0.80, FP 0.56, count error 3; int8 size about 29 MB versus 15 MB and YOLOX fails recall; Core ML works at float32 with parity 8.31e-4 and 41 to 50 ms warm on the M5 but every compressed package fails parity; branch chosen 2026-10-21 is scaling YOLOX (configs/yolox_s_d1.py, 8.94M params, about 9 MB int8), with the training run awaiting explicit go-ahead) |
| 5 | BoulderVision video analysis (experimental) | Not Started |

Native migration milestones (the app track since 2026-10-19):

| Milestone | Description | Status |
|-----------|-------------|--------|
| M0 | Decision lock, Xcode project, GRDB migrations, test harness | Complete (Xcode project itself pending user Xcode install) |
| M1 | Domain, data, backup port (byte-compatible .cybersend) | Complete (158 tests green; legacy import compat proven) |
| M2 | SwiftUI logbook (quick-log, sessions, settings) | Complete (190 package + 16 app + 5 UI tests green; 4-tap quick log and restore gate proven) |
| M3 | Photo capture and tagging MVP (Phase 2 gate unchanged) | Complete (258 package + 23 app + 11 UI tests green; capture, tagging canvas, real fall holds, stats; device dogfood gate items pending) |
| M4 | Grade normalization port | Not Started |
| M5 | Hold detection (Core ML, parity gate, eval gates) | Not Started |
| M6 | BoulderVision video analysis (experimental flag) | Not Started |

UI overhaul (the current track, started 2026-10-21):

| Item | Description | Status |
|------|-------------|--------|
| UI-1 | Theme: Dracula dark first, Alucard light variant, accent versus accentSolid tokens | Complete |
| UI-2 | Settings regrouped (Appearance, Defaults, Gyms and Grade schemes) with routes moved off the Logbook | Complete |
| UI-3 | Per attempt RPE, Project outcome retired (history rewritten to fail) | Complete |
| UI-4 | Problems catalog fifth tab (list, detail, history, archive, archived filter) | Complete |
| UI-5 | Quick log climb dropdown (tap budget 5, or 3 when the climb is already selected) | Complete |
| UI-6 | Home: session card, 20 week consistency heatmap, last three sessions, last three climbs | Complete |
| UI-7 | Session editor: add and edit a problem inline (the sheet continues into the photo section) | Complete |
| UI-8 | Session media: photo or video on any session, library import plus playback only | Complete |
| UI-9 | Problem editor restructure: details group with a gym picker, category grid, one Tag holds row, compact Manage | Complete |
| UI-10 | Problem detail: gym, categories, read only View hold stats, tagging only inside the editor | Complete |
| UI-11 | Catalog rows show gym and categories; filters for gym, level, category, and climb status | Complete |
| UI-12 | Open session: a card per added climb, Add Climb / Edit Problem / New Problem side by side, attempts editable live | Complete |
| UI-13 | Visual pass: themed text fields, outcome coloured buttons, wrapped catalog filters, single photo empty state, purple climbing app icon | Complete |

Pose v1 (video analysis, approved 2026-10-21; Vision body pose, no hold dependency):

| Phase | Description | Status |
|-------|-------------|--------|
| P0 | Filming contract, clip corpus, Vision pose spike measured on device | In Progress |
| P1 | Extraction service: AVAssetReader, Vision adapter, resumable analysis actor | Not Started |
| P2 | Analysis records, migration 006, retention default change | Not Started |
| P3 | Tier A metrics: attempt window, progress curve, fall, smoothness, hesitation map | Not Started |
| P4 | Guided recorder | Not Started |
| P5 | Review UI: overlay, timeline, summary card, session card, Videos tab | Not Started |
| P6 | Gated comparison, Tier B metrics: dyno, cut feet, rest | Not Started |

## Deep Docs

- [Requirements](docs/requirements.md)
- [Architecture](docs/architecture.md)
- [Decisions](docs/decisions.md)
- [Research](docs/research.md)
- [Reviews](docs/reviews.md)
- [Tests](docs/tests.md)
