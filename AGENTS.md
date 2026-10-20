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
| 4 | AI hold detection (Apache-2.0 self-trained) | Not Started |
| 5 | BoulderVision video analysis (experimental) | Not Started |

Native migration milestones (the app track since 2026-10-19):

| Milestone | Description | Status |
|-----------|-------------|--------|
| M0 | Decision lock, Xcode project, GRDB migrations, test harness | Complete (Xcode project itself pending user Xcode install) |
| M1 | Domain, data, backup port (byte-compatible .cybersend) | Complete (158 tests green; legacy import compat proven) |
| M2 | SwiftUI logbook (quick-log, sessions, settings) | In Progress |
| M3 | Photo capture and tagging MVP (Phase 2 gate unchanged) | Not Started |
| M4 | Grade normalization port | Not Started |
| M5 | Hold detection (Core ML, parity gate, eval gates) | Not Started |
| M6 | BoulderVision video analysis (experimental flag) | Not Started |

## Deep Docs

- [Requirements](docs/requirements.md)
- [Architecture](docs/architecture.md)
- [Decisions](docs/decisions.md)
- [Research](docs/research.md)
- [Reviews](docs/reviews.md)
- [Tests](docs/tests.md)
