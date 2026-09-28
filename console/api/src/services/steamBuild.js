// Best-effort read of the installed game's Steam build id. The appmanifest
// lives in the orchestrator's dune-server volume, which the console does not
// mount, so it is read through `docker compose exec` the same way
// runtime/scripts/version.sh does. Any failure yields null: the build id is
// provenance metadata, never a requirement.

import { spawn } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

const DEFAULT_STEAM_APP_ID = "4754530";
const CACHE_MS = 10 * 60 * 1000;
let cache = null; // { value, expiresAt }

export function steamAppId(repoRoot = process.cwd(), env = process.env) {
  if (/^\d+$/.test(String(env.STEAM_APP_ID || ""))) return String(env.STEAM_APP_ID);
  const envPath = resolve(repoRoot, ".env");
  if (existsSync(envPath)) {
    const match = readFileSync(envPath, "utf8").match(/^\s*STEAM_APP_ID\s*=\s*["']?(\d+)["']?\s*$/m);
    if (match) return match[1];
  }
  return DEFAULT_STEAM_APP_ID;
}

export function parseAppManifestBuildId(text) {
  const match = String(text || "").match(/"buildid"\s+"(\d+)"/i);
  return match ? match[1] : null;
}

export async function readSteamBuildId({ repoRoot = process.cwd(), spawnImpl = spawn, timeoutMs = 5000, useCache = true } = {}) {
  if (useCache && cache && cache.expiresAt > Date.now()) return cache.value;
  const appId = steamAppId(repoRoot);
  const value = await new Promise((done) => {
    let stdout = "";
    let child;
    try {
      child = spawnImpl("docker", ["compose", "exec", "-T", "orchestrator", "cat", `/srv/dune/server/steamapps/appmanifest_${appId}.acf`], {
        shell: false,
        env: { ...process.env },
        cwd: process.env.DUNE_DOCKER_DIR || repoRoot
      });
    } catch {
      done(null);
      return;
    }
    const timer = setTimeout(() => child.kill("SIGTERM"), timeoutMs);
    child.stdout?.on("data", (chunk) => {
      if (stdout.length < 65536) stdout += chunk.toString();
    });
    child.on("error", () => {
      clearTimeout(timer);
      done(null);
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      done(code === 0 ? parseAppManifestBuildId(stdout) : null);
    });
  });
  if (useCache) cache = { value, expiresAt: Date.now() + CACHE_MS };
  return value;
}

export function _resetSteamBuildCacheForTests() {
  cache = null;
}
