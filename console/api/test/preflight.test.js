import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { engineChecks } from "../src/preflight.js";

const DOCKER = { kind: "docker", mountSuffix: "", buildKit: null };
const PODMAN = { kind: "podman", mountSuffix: "z", buildKit: "0" };
const MISSING_SOCKET = "/nonexistent/dune-preflight/docker.sock";

// The Docker CLI, not the engine behind it, writes these messages, so a Podman
// host produces the same text.
const DENIED = "Got permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock";
const NOT_RUNNING = "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?";

function failing(output) {
  return () => {
    const error = new Error("Command failed");
    error.stderr = output;
    throw error;
  };
}

function checkNamed(checks, name) {
  return checks.find((entry) => entry.name === name);
}

test("preflight names the detected container engine", () => {
  const docker = checkNamed(engineChecks({ engine: DOCKER, run: () => "Docker version 27.3.1", socketPath: MISSING_SOCKET }), "Container engine");
  assert.deepEqual(docker, { name: "Container engine", status: "info", message: "docker", detail: "" });

  const podman = checkNamed(engineChecks({ engine: PODMAN, run: () => "Docker version 27.3.1", socketPath: MISSING_SOCKET }), "Container engine");
  assert.equal(podman.status, "info");
  assert.equal(podman.message, "podman");
  assert.match(podman.detail, /Docker-compatible API socket/);
});

test("preflight passes the engine checks straight through on a healthy host", () => {
  const calls = [];
  const socketDir = mkdtempSync(join(tmpdir(), "dune-preflight-sock-"));
  const socketPath = join(socketDir, "docker.sock");
  const server = createServer();
  try {
    server.listen(socketPath);
    const checks = engineChecks({
      engine: PODMAN,
      socketPath,
      run: (args) => {
        calls.push(args);
        if (args[0] === "--version") return "Docker version 27.3.1, build ce12230\n";
        if (args[0] === "compose") return "Docker Compose version v2.29.7\n";
        return "Client:\n Version: 27.3.1\n";
      }
    });
    assert.deepEqual(calls, [["--version"], ["compose", "version"], ["info"]]);
    assert.deepEqual(checks.filter((entry) => entry.status !== "pass").map((entry) => entry.name), ["Container engine"]);
    assert.equal(checkNamed(checks, "Docker CLI").message, "Docker version 27.3.1, build ce12230");
    assert.match(checkNamed(checks, "Docker socket").message, /^Socket group id: \d+, mode: 0\d+$/);
  } finally {
    server.close();
    rmSync(socketDir, { recursive: true, force: true });
  }
});

test("preflight keeps the Docker host's remediation advice unchanged", () => {
  const checks = engineChecks({ engine: DOCKER, run: failing(DENIED), socketPath: MISSING_SOCKET });
  assert.deepEqual(checkNamed(checks, "Docker daemon"), {
    name: "Docker daemon",
    status: "fail",
    message: "Docker socket permission denied.",
    detail: [
      "The Web UI can see Docker, but this container cannot access the Docker socket.",
      "Set DOCKER_SOCKET_GID to the Docker socket group id, then restart the Web UI:",
      "  DOCKER_SOCKET_GID=$(stat -c '%g' /var/run/docker.sock) dune console restart"
    ].join("\n")
  });
  assert.deepEqual(checkNamed(checks, "Docker socket"), {
    name: "Docker socket",
    status: "fail",
    message: "Docker socket is not mounted.",
    detail: "The Web UI container needs /var/run/docker.sock mounted so it can manage local Docker services."
  });

  const stopped = engineChecks({ engine: DOCKER, run: failing(NOT_RUNNING), socketPath: MISSING_SOCKET });
  assert.equal(checkNamed(stopped, "Docker daemon").message, "Docker daemon is not running or cannot be reached.");
  assert.match(checkNamed(stopped, "Docker daemon").detail, /Start Docker on the server/);
  assert.equal(checkNamed(stopped, "Docker CLI").message, "Docker is missing.");
});

test("preflight tells a Podman host to start podman.socket instead of Docker", () => {
  const checks = engineChecks({ engine: PODMAN, run: failing(NOT_RUNNING), socketPath: MISSING_SOCKET });
  const daemon = checkNamed(checks, "Docker daemon");
  assert.equal(daemon.status, "fail");
  assert.match(daemon.message, /Podman API socket/);
  assert.match(daemon.detail, /systemctl enable --now podman\.socket/);
  assert.doesNotMatch(daemon.detail, /Docker Desktop/);
  assert.match(checkNamed(checks, "Docker socket").detail, /systemctl enable --now podman\.socket/);
  assert.match(checkNamed(checks, "Docker CLI").detail, /Docker-compatible socket/);
  assert.match(checkNamed(checks, "Docker Compose").detail, /Compose v2 plugin/);
});

// The advice a rootful Podman host must not be given first: its socket is
// root:root, so stat returns 0 and adding group 0 changes nothing.
test("preflight tells a Podman host how to give the socket a group before reading its id", () => {
  const daemon = checkNamed(engineChecks({ engine: PODMAN, run: failing(DENIED), socketPath: MISSING_SOCKET }), "Docker daemon");
  assert.equal(daemon.status, "fail");
  const advice = daemon.detail.split("\n");
  const group = advice.findIndex((line) => /SocketGroup=/.test(line));
  const readBack = advice.findIndex((line) => /stat -c/.test(line));
  assert.ok(group > -1 && readBack > group, daemon.detail);
  assert.match(daemon.detail, /equivalent to root/);
});

test("preflight reports an unclassified engine failure with the command output", () => {
  const checks = engineChecks({ engine: PODMAN, run: failing("Error: short-name resolution enforced but cannot prompt without a TTY"), socketPath: MISSING_SOCKET });
  const daemon = checkNamed(checks, "Docker daemon");
  assert.match(daemon.message, /Podman is installed but its API socket/);
  assert.match(daemon.detail, /short-name resolution/);
});
