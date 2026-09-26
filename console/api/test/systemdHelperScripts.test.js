import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");

const helperScripts = new Map([
  ["runtime/scripts/restart-schedule.sh", 3],
  ["runtime/scripts/ip-change-restart.sh", 3],
  ["runtime/scripts/shutdown-protection.sh", 4],
  ["runtime/scripts/db.sh", 3],
  ["runtime/scripts/update.sh", 3]
]);

test("host systemd helpers explicitly run as root", () => {
  for (const [relativePath, expectedHelpers] of helperScripts) {
    const source = readFileSync(resolve(repoRoot, relativePath), "utf8");
    const helpers = source
      .split("\n")
      .filter((line) => line.includes("docker run --rm") && line.includes("--privileged"));

    assert.equal(helpers.length, expectedHelpers, `${relativePath} helper count changed`);
    for (const helper of helpers) {
      assert.match(helper, /docker run --rm --user 0:0 --privileged/,
        `${relativePath} must run its host systemd helper as root`);
    }
  }
});

// Every place that binds the host root and chroots into it. The count is the
// number of such mounts in the file, not the number of functions.
const hostRootHelpers = new Map([
  ["runtime/scripts/restart-schedule.sh", 3],
  ["runtime/scripts/ip-change-restart.sh", 3],
  ["runtime/scripts/shutdown-protection.sh", 4],
  ["runtime/scripts/db.sh", 3],
  ["runtime/scripts/update.sh", 3],
  ["runtime/scripts/memory-swap.sh", 1]
]);

// Collapse shell line continuations so one invocation is one string.
const invocationsOf = (source) =>
  source
    .replace(/\\\n\s*/g, " ")
    .split("\n")
    .filter((line) => line.includes("docker run --rm") && line.includes("--privileged"));

test("host-root helpers exempt the bind from SELinux relabelling", () => {
  for (const [relativePath, expectedMounts] of hostRootHelpers) {
    const source = readFileSync(resolve(repoRoot, relativePath), "utf8");

    // The splice expands to nothing unless something built the array.
    assert.ok(
      /^\s*(\.|source) runtime\/scripts\/runtime-env\.sh/m.test(source) ||
        /^DUNE_ENGINE_LABEL_DISABLE_ARGS=\(\)/m.test(source),
      `${relativePath} splices DUNE_ENGINE_LABEL_DISABLE_ARGS without defining it`);

    const helpers = invocationsOf(source).filter((line) => line.includes("-v /:/host"));
    assert.equal(helpers.length, expectedMounts, `${relativePath} host-root mount count changed`);

    for (const helper of helpers) {
      // Podman relabels bind mounts on request, and a request on / would
      // rewrite the SELinux context of the whole host filesystem. These mounts
      // opt out instead. Docker has nothing to opt out of, where the splice is
      // an empty array.
      assert.match(helper, /"\$\{DUNE_ENGINE_LABEL_DISABLE_ARGS\[@\]\}"/,
        `${relativePath} must disable relabelling on its host-root bind`);
      assert.match(helper, /-v \/:\/host /,
        `${relativePath} must not add mount options to its host-root bind`);
    }
  }
});

test("generated units never hardcode the Docker engine unit", () => {
  for (const relativePath of helperScripts.keys()) {
    const source = readFileSync(resolve(repoRoot, relativePath), "utf8");

    // systemd ignores an ordering dependency on a unit that does not exist
    // without saying so, so a hardcoded docker.service is a guarantee that
    // disappears silently on a Podman host. lib/engine.sh names the right one.
    assert.doesNotMatch(source, /^(Wants|After|Requires|BindsTo)=.*docker\.service/m,
      `${relativePath} must order its generated units through dune_engine_systemd_unit_ordering`);
  }
});

test("scheduled restart jobs run as the host checkout owner", () => {
  const source = readFileSync(resolve(repoRoot, "runtime/scripts/restart-schedule.sh"), "utf8");

  assert.match(source, /source runtime\/scripts\/host-file-ownership\.sh/);
  assert.match(source, /read -r HOST_SERVICE_UID HOST_SERVICE_GID <<< "\$\(dune_resolve_host_owner\)"/);
  assert.equal(source.match(/^User=\$HOST_SERVICE_UID$/gm)?.length, 2);
  assert.equal(source.match(/^Group=\$HOST_SERVICE_GID$/gm)?.length, 2);
  assert.equal(source.match(/^User=\$\{DUNE_HOST_SERVICE_UID\}$/gm)?.length, 2);
  assert.equal(source.match(/^Group=\$\{DUNE_HOST_SERVICE_GID\}$/gm)?.length, 2);
  assert.match(source, /reexec_scheduled_job_as_install_owner/);
  assert.match(source, /exec setpriv[\s\S]*?--reuid="\$target_user"[\s\S]*?--init-groups/);
  assert.match(source, /runtime\/scripts\/sietches\.sh preflight[\s\S]*?usersettings\.py preflight[\s\S]*?usersettings\.py materialize-current[\s\S]*?runtime\/scripts\/stop-all\.sh/);
});

test("shell self-update helper uses host ownership and Docker socket group", () => {
  const source = readFileSync(resolve(repoRoot, "runtime/scripts/self-update.sh"), "utf8");

  assert.match(source, /--user "\$\{DUNE_HOST_UID:-0\}:\$\{DUNE_HOST_GID:-0\}"/);
  assert.match(source, /--group-add "\$\{DOCKER_SOCKET_GID:-0\}"/);
  assert.match(source, /-e "DUNE_HOST_UID=\$\{DUNE_HOST_UID:-0\}"/);
  assert.match(source, /-e "DUNE_HOST_GID=\$\{DUNE_HOST_GID:-0\}"/);
});
