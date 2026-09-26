import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import { detectContainerEngine } from "../src/engine.js";

// The real runtime/scripts/lib/engine.sh, which is the point: these assertions
// fail if the shell seam ever stops answering the way the console reads it.
const repoRoot = fileURLToPath(new URL("../../../", import.meta.url));

test("container engine detection reads Podman's behaviour from the shell seam", () => {
  const engine = detectContainerEngine({ env: { PATH: process.env.PATH, DUNE_CONTAINER_ENGINE: "podman" }, repoRoot });
  assert.deepEqual(engine, { kind: "podman", mountSuffix: "z", buildKit: "0" });
});

test("container engine detection leaves Docker exactly as it was", () => {
  const engine = detectContainerEngine({ env: { PATH: process.env.PATH, DUNE_CONTAINER_ENGINE: "docker" }, repoRoot });
  assert.deepEqual(engine, { kind: "docker", mountSuffix: "", buildKit: null });
});

test("container engine detection ignores stale seam values inherited from the caller", () => {
  const engine = detectContainerEngine({
    env: {
      PATH: process.env.PATH,
      DUNE_CONTAINER_ENGINE: "docker",
      DUNE_ENGINE_KIND: "podman",
      DUNE_ENGINE_MOUNT_SUFFIX: "z",
      DOCKER_BUILDKIT: "0"
    },
    repoRoot
  });
  assert.deepEqual(engine, { kind: "docker", mountSuffix: "", buildKit: null });
});

test("container engine detection falls back to Docker behaviour when the seam cannot be read", () => {
  const engine = detectContainerEngine({
    env: { PATH: process.env.PATH, DUNE_CONTAINER_ENGINE: "podman" },
    repoRoot: mkdtempSync(join(tmpdir(), "dune-engine-seam-"))
  });
  assert.deepEqual(engine, { kind: "docker", mountSuffix: "", buildKit: null });
});
