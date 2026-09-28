import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { appendRestartHistory, readRestartHistory, recordTaskRestart, restartDescriptor } from "../src/services/restartHistory.js";

test("restart history classifies battlegroup, map, and service restart tasks", () => {
  assert.equal(restartDescriptor("restartAll").scope, "battlegroup");
  assert.deepEqual(restartDescriptor("mapsRespawn", { target: 32, restartLabel: "The Pit" }), {
    scope: "map", target: "The Pit", map: "", partitionId: "32", reason: "Manual restart"
  });
  assert.equal(restartDescriptor("restartService", { service: "director" }).scope, "service");
  assert.equal(restartDescriptor("updateCheck"), null);
});

test("restart history returns newest rows and the latest successful battlegroup restart", () => {
  const file = join(mkdtempSync(join(tmpdir(), "restart-history-")), "history.jsonl");
  const config = { restartHistoryFile: file };
  appendRestartHistory(file, { id: "a", startedAt: "2026-01-01T00:00:00Z", finishedAt: "2026-01-01T00:01:00Z", scope: "battlegroup", target: "Battlegroup", source: "Scheduled", reason: "Scheduled restart", result: "Succeeded", durationSeconds: 60 });
  appendRestartHistory(file, { id: "b", startedAt: "2026-01-02T00:00:00Z", finishedAt: "2026-01-02T00:00:05Z", scope: "map", target: "Hagga Basin", source: "Console", reason: "Manual restart", result: "Failed", durationSeconds: 5 });
  const result = readRestartHistory(config);
  assert.deepEqual(result.rows.map((row) => row.id), ["b", "a"]);
  assert.equal(result.lastBattlegroupRestart.id, "a");
});

test("completed Console restart tasks are recorded with their outcome and duration", () => {
  const file = join(mkdtempSync(join(tmpdir(), "restart-history-task-")), "history.jsonl");
  const config = { restartHistoryFile: file };
  const row = recordTaskRestart(config, {
    id: "task-1",
    operation: "restartAll",
    status: "succeeded",
    startedAt: "2026-01-03T00:00:00Z",
    finishedAt: "2026-01-03T00:01:15Z"
  });

  assert.equal(row.scope, "battlegroup");
  assert.equal(row.result, "Succeeded");
  assert.equal(row.durationSeconds, 75);
  assert.deepEqual(readRestartHistory(config).rows, [row]);
});

test("the latest Battlegroup restart remains visible beyond the table row limit", () => {
  const file = join(mkdtempSync(join(tmpdir(), "restart-history-limit-")), "history.jsonl");
  const config = { restartHistoryFile: file };
  appendRestartHistory(file, { id: "bg", finishedAt: "2026-01-01T00:00:00Z", scope: "battlegroup", result: "Succeeded" });
  for (let index = 0; index < 101; index += 1) {
    appendRestartHistory(file, { id: `map-${index}`, finishedAt: `2026-01-02T00:${String(index % 60).padStart(2, "0")}:00Z`, scope: "map", result: "Succeeded" });
  }

  const result = readRestartHistory(config);
  assert.equal(result.rows.length, 100);
  assert.equal(result.rows.some((row) => row.id === "bg"), false);
  assert.equal(result.lastBattlegroupRestart.id, "bg");
});
