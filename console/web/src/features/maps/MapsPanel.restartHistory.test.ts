import { describe, expect, it } from "vitest";
import type { RestartHistoryResponse } from "../../api/server";
import { latestSuccessfulMapRestart } from "./MapsPanel";

const history: RestartHistoryResponse = {
  lastBattlegroupRestart: null,
  rows: [
    { id: "failed", startedAt: "", finishedAt: "2026-09-27T03:00:00Z", durationSeconds: 1, scope: "map", target: "Sietch Two", map: "Survival_1", partitionId: "2", source: "Console", reason: "Sietch restart", result: "Failed" },
    { id: "map-wide", startedAt: "", finishedAt: "2026-09-27T02:00:00Z", durationSeconds: 1, scope: "map", target: "Survival", map: "Survival_1", partitionId: "", source: "Console", reason: "Manual restart", result: "Succeeded" },
    { id: "partition", startedAt: "", finishedAt: "2026-09-27T01:00:00Z", durationSeconds: 1, scope: "map", target: "Sietch Two", map: "Survival_1", partitionId: "2", source: "Console", reason: "Sietch restart", result: "Succeeded" }
  ]
};

describe("selected map restart history", () => {
  it("uses the latest successful exact partition restart for child maps", () => {
    expect(latestSuccessfulMapRestart(history, "Survival_1", "2")?.id).toBe("partition");
  });

  it("can include a map-wide restart for the primary map details", () => {
    expect(latestSuccessfulMapRestart(history, "Survival_1", "1", true)?.id).toBe("map-wide");
  });
});
