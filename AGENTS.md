# CyberSend

Local-first bouldering and climbing tracker for iOS. React Native (Expo) and TypeScript, SQLite on device, zero accounts, no cloud dependency for core features. iOS first.

## Quick Commands

Expected Expo commands. Verify after Phase 1 scaffold.

```bash
npx expo start          # dev server
npx expo run:ios        # native iOS build
npm test                # jest test suite
npx jest --watch        # focused test loop
npx tsc --noEmit        # type check
npx expo lint           # lint, confirm script after scaffold
```

## Conventions

- TypeScript strict mode. No implicit any, no unused locals, no unchecked index access.
- No em dashes, double hyphens, or dash equivalents in code, comments, or docs. Use full punctuation.
- snake_case for local variables and function parameters. camelCase for exports and types.
- All data access goes through repositories. Screens and hooks never call SQLite directly.
- Canvas and vision coordinates are normalized (0..1) at the boundary. Convert to pixels only in UI layers.
- Local first: every feature must work offline. Sync and network paths are optional.
- Tests required for domain logic and repositories.

## Project Map

Planned layout, created during Phase 1.

```
src/domain/      entities, grade normalization, pure logic
src/data/        SQLite schema, repositories, migrations
src/features/    feature modules (photos, sessions, tagging, AI)
src/ui/          shared components, theme, canvas primitives
assets/models/   ONNX and TFLite model files
docs/            architecture, decisions, research, reviews, tests
```

## Status

| Phase | Description | Status |
|-------|-------------|--------|
| 0 | Spikes and technical validation | In Progress |
| 1 | Core foundation | Not Started |
| 2 | Photo capture and tagging MVP | Not Started |
| 3 | Grade normalization | Not Started |
| 4 | AI hold detection (Apache-2.0 self-trained) | Not Started |
| 5 | BoulderVision video analysis (experimental) | Not Started |

## Deep Docs

- [Requirements](docs/requirements.md)
- [Architecture](docs/architecture.md)
- [Decisions](docs/decisions.md)
- [Research](docs/research.md)
- [Reviews](docs/reviews.md)
- [Tests](docs/tests.md)
