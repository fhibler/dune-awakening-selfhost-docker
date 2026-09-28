import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { redact } from "../redact.js";
import { writeJsonAtomic } from "../jsonStore.js";

const SETTINGS_PATH = "runtime/generated/player-list-settings.json";

export const PLAYER_INACTIVE_WEEKS_DEFAULT = null;
export const PLAYER_INACTIVE_WEEKS_MIN = 1;
export const PLAYER_INACTIVE_WEEKS_MAX = 8;

function settingsFile(repoRoot) {
  return resolve(repoRoot || "", SETTINGS_PATH);
}

function badRequest(message) {
  return Object.assign(new Error(message), { statusCode: 400 });
}

export function readPlayerListSettings(repoRoot) {
  const file = settingsFile(repoRoot);
  if (!existsSync(file)) return {};
  try {
    const value = JSON.parse(readFileSync(file, "utf8"));
    if (!value || typeof value !== "object" || Array.isArray(value)) return {};
    const weeks = Number(value.inactiveWeeks);
    return Number.isInteger(weeks) && weeks >= PLAYER_INACTIVE_WEEKS_MIN && weeks <= PLAYER_INACTIVE_WEEKS_MAX
      ? { inactiveWeeks: weeks }
      : {};
  } catch (error) {
    console.warn(`Ignoring unreadable player-list settings: ${redact(error?.message || "Unexpected error.")}`);
    return {};
  }
}

export function resolvePlayerInactiveWeeks(repoRoot) {
  return readPlayerListSettings(repoRoot).inactiveWeeks ?? PLAYER_INACTIVE_WEEKS_DEFAULT;
}

export function playerListSettingsView(repoRoot) {
  const stored = readPlayerListSettings(repoRoot);
  return {
    settings: { inactiveWeeks: stored.inactiveWeeks ?? PLAYER_INACTIVE_WEEKS_DEFAULT },
    defaults: { inactiveWeeks: PLAYER_INACTIVE_WEEKS_DEFAULT },
    limits: { inactiveWeeks: { min: PLAYER_INACTIVE_WEEKS_MIN, max: PLAYER_INACTIVE_WEEKS_MAX } },
    source: stored.inactiveWeeks === undefined ? "default" : "console"
  };
}

export function savePlayerListSettings(repoRoot, payload) {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    throw badRequest("Player visibility settings must be an object.");
  }
  if (!Object.hasOwn(payload, "inactiveWeeks")) {
    throw badRequest("inactiveWeeks is required.");
  }
  if (payload.inactiveWeeks === null) {
    writeJsonAtomic(settingsFile(repoRoot), {}, 0o600);
    return playerListSettingsView(repoRoot);
  }
  const weeks = Number(payload.inactiveWeeks);
  if (!Number.isInteger(weeks) || weeks < PLAYER_INACTIVE_WEEKS_MIN || weeks > PLAYER_INACTIVE_WEEKS_MAX) {
    throw badRequest(`inactiveWeeks must be a whole number between ${PLAYER_INACTIVE_WEEKS_MIN} and ${PLAYER_INACTIVE_WEEKS_MAX}.`);
  }
  writeJsonAtomic(settingsFile(repoRoot), { inactiveWeeks: weeks }, 0o600);
  return playerListSettingsView(repoRoot);
}
