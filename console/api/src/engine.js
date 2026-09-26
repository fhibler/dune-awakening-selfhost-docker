import { execFileSync } from "node:child_process";
import { resolve } from "node:path";
import { resolveRepoRoot } from "./config.js";

// The console's view of the container engine.
//
// runtime/scripts/lib/engine.sh is the single description of how Podman
// differs from Docker, and ~660 shell call sites obey it. Restating any of
// that here would create a second description free to drift from the one that
// matters, so this module does not decide anything: it runs the seam and reads
// the DUNE_ENGINE_* variables it exports. The seam is POSIX sh, idempotent and
// side-effect free on source, and lives in the repository this container
// already mounts.
//
// Only the fields the console actually consumes are surfaced. The rest of the
// contract (restart policy, systemd unit, image prefix, log options) belongs to
// callers that generate units or run containers from the shell.
const ENGINE_SEAM = "runtime/scripts/lib/engine.sh";

// What the console did before the seam existed. Used only when the seam cannot
// be read at all -- a console started outside the repository, or a shell that
// failed -- so an unresolvable engine behaves exactly as it does today instead
// of guessing at Podman.
const UNDETECTED = Object.freeze({ kind: "docker", mountSuffix: "", buildKit: null });

let detected = null;

// Cached: resolving shells out, several callers poll, and the engine behind a
// running console does not change.
export function containerEngine() {
  if (!detected) detected = detectContainerEngine();
  return detected;
}

export function detectContainerEngine({ env = process.env, repoRoot = resolveRepoRoot(env) } = {}) {
  const variables = readEngineSeam(env, repoRoot);
  if (!variables.DUNE_ENGINE_KIND) return UNDETECTED;
  return Object.freeze({
    kind: variables.DUNE_ENGINE_KIND,
    mountSuffix: variables.DUNE_ENGINE_MOUNT_SUFFIX || "",
    // The seam sets DOCKER_BUILDKIT only where Compose must not attempt a
    // BuildKit build. Null means it left the CLI's own default alone.
    buildKit: variables.DOCKER_BUILDKIT ?? null
  });
}

function readEngineSeam(env, repoRoot) {
  try {
    const output = execFileSync("/bin/sh", ["-c", '. "$1" || exit 1; env', "sh", resolve(repoRoot, ENGINE_SEAM)], {
      encoding: "utf8",
      // Detection asks the engine for its version, which hangs rather than
      // errors against a wedged socket -- the state a console most needs to
      // survive without blocking its own startup.
      timeout: 10000,
      stdio: ["ignore", "pipe", "ignore"],
      env: seamInput(env)
    });
    return parseEnvironment(output);
  } catch {
    return {};
  }
}

// Anything the seam itself exports is cleared from its input so the answer is
// the seam's own rather than a stale copy inherited through a process tree.
// DUNE_CONTAINER_ENGINE (the operator's documented override) and DOCKER_HOST
// are inputs to detection, not outputs, and stay.
function seamInput(env) {
  return Object.fromEntries(Object.entries(env)
    .filter(([name]) => !name.startsWith("DUNE_ENGINE_") && name !== "DOCKER_BUILDKIT"));
}

function parseEnvironment(output) {
  const variables = {};
  for (const line of String(output).split("\n")) {
    const match = /^(DUNE_ENGINE_[A-Z_]+|DOCKER_BUILDKIT)=(.*)$/.exec(line);
    if (match) variables[match[1]] = match[2];
  }
  return variables;
}
