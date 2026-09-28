import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync, mkdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import {
  PLAYER_INACTIVE_WEEKS_DEFAULT,
  playerListSettingsView,
  readPlayerListSettings,
  resolvePlayerInactiveWeeks,
  savePlayerListSettings
} from "../src/services/playerListSettings.js";

function withRoot(run) {
  const root = mkdtempSync(join(tmpdir(), "player-list-settings-"));
  try { return run(root); } finally { rmSync(root, { recursive: true, force: true }); }
}

test("player visibility defaults to never hiding inactive players", () => withRoot((root) => {
  assert.equal(PLAYER_INACTIVE_WEEKS_DEFAULT, null);
  assert.equal(resolvePlayerInactiveWeeks(root), null);
  assert.deepEqual(playerListSettingsView(root), {
    settings: { inactiveWeeks: null },
    defaults: { inactiveWeeks: null },
    limits: { inactiveWeeks: { min: 1, max: 8 } },
    source: "default"
  });
}));

test("player visibility saves a bounded whole-week value with owner-only permissions", () => withRoot((root) => {
  const result = savePlayerListSettings(root, { inactiveWeeks: 6 });
  assert.equal(result.settings.inactiveWeeks, 6);
  assert.deepEqual(readPlayerListSettings(root), { inactiveWeeks: 6 });
  const file = join(root, "runtime/generated/player-list-settings.json");
  assert.equal(JSON.parse(readFileSync(file, "utf8")).inactiveWeeks, 6);
  assert.equal(statSync(file).mode & 0o777, 0o600);
}));

test("player visibility reset restores the never-hide default", () => withRoot((root) => {
  savePlayerListSettings(root, { inactiveWeeks: 8 });
  const result = savePlayerListSettings(root, { inactiveWeeks: null });
  assert.equal(result.settings.inactiveWeeks, null);
  assert.equal(result.source, "default");
}));

test("player visibility rejects malformed and out-of-range values", () => withRoot((root) => {
  for (const payload of [null, [], {}, { inactiveWeeks: 0 }, { inactiveWeeks: 9 }, { inactiveWeeks: 1.5 }, { inactiveWeeks: "two" }]) {
    assert.throws(() => savePlayerListSettings(root, payload), /object|required|whole number/);
  }
}));

test("player visibility ignores corrupt persisted state", () => withRoot((root) => {
  const dir = join(root, "runtime/generated");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "player-list-settings.json"), "{broken", "utf8");
  assert.deepEqual(readPlayerListSettings(root), {});
  assert.equal(resolvePlayerInactiveWeeks(root), null);
}));
