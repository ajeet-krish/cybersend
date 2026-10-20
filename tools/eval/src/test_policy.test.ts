/**
 * Unit tests for the one gated test run policy (test_policy.ts).
 * Run: npm test (node --test).
 */

import assert from "node:assert/strict";
import path from "node:path";
import { test } from "node:test";

import {
  TEST_ACCEPT_FLAG,
  TEST_LEDGER_FILE,
  buildLedgerEntry,
  defaultReportName,
  formatLedgerEntry,
  gitDescribe,
  requireTestRunAcceptance,
  splitKind,
} from "./test_policy.ts";

const MERGED_DIR = path.join("..", "train", "datasets", "merged");

test("splitKind: the frozen test split is detected by its final path segment", () => {
  assert.equal(splitKind(path.join(MERGED_DIR, "test")), "test");
  assert.equal(splitKind(path.join(MERGED_DIR, "test") + path.sep), "test");
  assert.equal(splitKind(path.resolve(MERGED_DIR, "test")), "test");
});

test("splitKind: val and anything else are not the test split", () => {
  assert.equal(splitKind(path.join(MERGED_DIR, "val")), "other");
  assert.equal(splitKind(path.join(MERGED_DIR, "train")), "other");
  assert.equal(splitKind(path.join(MERGED_DIR, "test_images")), "other");
  assert.equal(splitKind(MERGED_DIR), "other");
});

test("defaultReportName: val is the default split, test only for test runs", () => {
  assert.equal(defaultReportName("other"), "d1_val_eval.json");
  assert.equal(defaultReportName("test"), "d1_test_eval.json");
});

test("requireTestRunAcceptance: test split without the flag fails fast", () => {
  assert.throws(
    () => requireTestRunAcceptance("test", false),
    (error: Error) => error.message.includes(TEST_ACCEPT_FLAG),
  );
});

test("requireTestRunAcceptance: test split with the flag passes", () => {
  requireTestRunAcceptance("test", true);
});

test("requireTestRunAcceptance: non-test splits never need the flag", () => {
  requireTestRunAcceptance("other", false);
});

test("buildLedgerEntry carries the audit fields as one JSON line", () => {
  const entry = buildLedgerEntry({
    timestamp: "2026-10-19T00:00:00.000Z",
    model_id: "holds_detector_d1",
    model_path: path.join("tools", "train", "artifacts", "holds_detector_d1.onnx"),
    report_path: path.join("tools", "eval", "reports", "d1_test_eval.json"),
    split_dir: path.join("tools", "train", "datasets", "merged", "test"),
    git_describe: "289221b",
    gate: true,
    confidence: 0.45,
  });
  assert.equal(entry.policy, "one gated test run");
  assert.equal(entry.accepted_one_test_run, true);
  assert.equal(entry.model_id, "holds_detector_d1");
  assert.equal(entry.git_describe, "289221b");

  const line = formatLedgerEntry(entry);
  assert.ok(line.endsWith("\n"));
  const parsed = JSON.parse(line) as Record<string, unknown>;
  assert.equal(typeof parsed.timestamp, "string");
  assert.equal(parsed.model_id, "holds_detector_d1");
  assert.equal(typeof parsed.report_path, "string");
  assert.equal(typeof parsed.git_describe, "string");
  assert.equal(parsed.gate, true);
  assert.equal(TEST_LEDGER_FILE, "test_ledger.jsonl");
});

test("gitDescribe returns a string or null without throwing", () => {
  const describe = gitDescribe(path.resolve("."));
  assert.ok(describe === null || typeof describe === "string");
  assert.equal(gitDescribe(path.join(path.sep, "does", "not", "exist")), null);
});
