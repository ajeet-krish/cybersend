# CyberSend Test Strategy

Last updated: 2026-10-19 (Phase 0, overall architecture)

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
