import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { spawnSync } from "node:child_process";

test("runtime restart history records scheduled restarts in the shared journal", () => {
  const historyFile = join(mkdtempSync(join(tmpdir(), "restart-history-script-")), "history.jsonl");
  const script = resolve("../../runtime/scripts/restart-history.sh");
  const result = spawnSync(script, [
    "record", "battlegroup", "Battlegroup", "Scheduled", "Scheduled restart", "Succeeded",
    "2026-09-27T00:00:00Z", "2026-09-27T00:00:12Z", "12"
  ], {
    cwd: resolve("../.."),
    env: { ...process.env, DUNE_RESTART_HISTORY_FILE: historyFile },
    encoding: "utf8"
  });

  assert.equal(result.status, 0, result.stderr);
  const row = JSON.parse(readFileSync(historyFile, "utf8").trim());
  assert.equal(row.scope, "battlegroup");
  assert.equal(row.source, "Scheduled");
  assert.equal(row.result, "Succeeded");
  assert.equal(row.durationSeconds, 12);
});
