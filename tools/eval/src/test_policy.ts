/**
 * One gated test run policy for the CyberSend hold detector eval harness.
 *
 * The frozen test split may only be scored with an explicit
 * `--i-accept-one-test-run` flag, and every accepted run appends one JSON line
 * to reports/test_ledger.jsonl (timestamp, model id, report path, git describe
 * when available). Model selection and threshold tuning happen on the val
 * split, so the ledger is the audit trail that shows how often the frozen
 * split was actually opened. See tools/eval/README.md.
 *
 * This module is pure logic plus one git call, so it is unit testable without
 * a model, a dataset, or a report.
 */

import { execFileSync } from "node:child_process";
import path from "node:path";

/** Flag that must be passed explicitly to score the frozen test split. */
export const TEST_ACCEPT_FLAG = "--i-accept-one-test-run";

/** Ledger file (newline delimited JSON), one line per accepted test run. */
export const TEST_LEDGER_FILE = "test_ledger.jsonl";

/** "test" when the split directory is the frozen test split, else "other". */
export type SplitKind = "test" | "other";

/**
 * A split directory counts as the frozen test split when its final path
 * segment is exactly "test" (for example ../train/datasets/merged/test).
 */
export function splitKind(splitDir: string): SplitKind {
  const normalized = path.resolve(splitDir);
  return path.basename(normalized) === "test" ? "test" : "other";
}

/** Default report file name for a split kind (val by default, test only for test runs). */
export function defaultReportName(kind: SplitKind): string {
  return kind === "test" ? "d1_test_eval.json" : "d1_val_eval.json";
}

/**
 * Throw unless the test split acceptance flag was given for a test split.
 * Non-test splits are always allowed; test splits without acceptance fail fast
 * before any model or data is loaded.
 */
export function requireTestRunAcceptance(kind: SplitKind, acceptedOneTestRun: boolean): void {
  if (kind === "test" && !acceptedOneTestRun) {
    throw new Error(
      `${TEST_ACCEPT_FLAG} is required to score the frozen test split (one gated test run policy). ` +
        "Select the operating point on the val split first, then run the test split once with the flag " +
        "and let reports/test_ledger.jsonl record the run.",
    );
  }
}

/** Inputs for one test ledger line (JSON keys are snake_case like the reports). */
export interface TestLedgerInput {
  readonly timestamp: string;
  readonly model_id: string;
  readonly model_path: string;
  readonly report_path: string;
  readonly split_dir: string;
  readonly git_describe: string | null;
  readonly gate: boolean;
  readonly confidence: number;
}

/** One line of reports/test_ledger.jsonl. */
export interface TestLedgerEntry extends TestLedgerInput {
  readonly policy: "one gated test run";
  readonly accepted_one_test_run: true;
}

export function buildLedgerEntry(input: TestLedgerInput): TestLedgerEntry {
  return {
    ...input,
    policy: "one gated test run",
    accepted_one_test_run: true,
  };
}

/** Serialize one ledger entry as a single JSON line (with trailing newline). */
export function formatLedgerEntry(entry: TestLedgerEntry): string {
  return `${JSON.stringify(entry)}\n`;
}

/**
 * `git describe --always --dirty` for the repository, or null when git or the
 * repository is unavailable (for example a source tarball).
 */
export function gitDescribe(repositoryRoot: string): string | null {
  try {
    const output = execFileSync("git", ["describe", "--always", "--dirty"], {
      cwd: repositoryRoot,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
    const trimmed = output.trim();
    return trimmed.length > 0 ? trimmed : null;
  } catch {
    return null;
  }
}
