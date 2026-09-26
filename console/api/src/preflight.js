import { existsSync, statSync, readFileSync } from "node:fs";
import { arch, freemem, platform, release, totalmem } from "node:os";
import { execFileSync } from "node:child_process";
import { createServer } from "node:net";
import { resolve } from "node:path";
import { resolvePorts } from "./config.js";
import { containerEngine } from "./engine.js";

export async function preflight(config) {
  const ports = configuredPorts(config.ports);
  const checks = [];
  checks.push(check("Operating system", "info", `${platform()} ${release()}`));
  checks.push(check("Architecture", arch() === "x64" ? "pass" : "warn", arch()));
  checks.push(cpuFlags());
  checks.push(check("RAM", totalmem() >= 16 * 1024 ** 3 ? "pass" : "warn", `${gb(totalmem())} GiB total, ${gb(freemem())} GiB free`));
  checks.push(diskCheck(config.repoRoot));
  checks.push(...engineChecks());
  checks.push(fileCheck("Runtime directory", config.repoRoot));
  checks.push(fileCheck("docker-compose.yml", resolve(config.repoRoot, "docker-compose.yml")));
  checks.push(fileCheck("dune command", config.duneScript));
  checks.push(fileCheck(".env", resolve(config.repoRoot, ".env"), true));
  checks.push(fileCheck("Funcom token", resolve(config.secretsDir, "funcom-token.txt"), true));
  checks.push(fileCheck("Generated runtime files", config.generatedDir, true));
  checks.push(fileCheck("Backup directory", resolve(config.repoRoot, "runtime/backups/db"), true));
  checks.push(...await Promise.all(ports.map(portCheck)));
  return { checks, summary: summarize(checks) };
}

// Accepts a resolved config.ports object (see config.js's resolvePorts())
// so this module has exactly one source of truth for stock port
// defaults, shared with every other consumer (db.js, server.js,
// duneDb.js, and the frontend via publicConfig()). Falls back to
// resolving from process.env directly only if called without a ports
// object (kept for backward-compat with any external caller/test that
// doesn't pass one).
function configuredPorts(ports) {
  const resolved = ports || resolvePorts();
  return [
    resolved.postgres,
    resolved.rmqGame,
    resolved.rmqGameHttp,
    resolved.rmqAdmin,
    resolved.textRouter,
    resolved.clientBase,
    resolved.clientBaseSecondary,
    resolved.igwBase,
    resolved.igwBaseSecondary,
    resolved.director
  ];
}

function check(name, status, message, detail = "") {
  return { name, status, message, detail };
}

function summarize(checks) {
  return {
    pass: checks.filter((c) => c.status === "pass").length,
    warn: checks.filter((c) => c.status === "warn").length,
    fail: checks.filter((c) => c.status === "fail").length
  };
}

function commandCheck(name, cmd, args) {
  try {
    const out = execFileSync(cmd, args, { encoding: "utf8", timeout: 5000, stdio: ["ignore", "pipe", "pipe"] });
    return check(name, "pass", out.split(/\r?\n/)[0]);
  } catch (error) {
    return check(name, "fail", "Not available or not reachable", String(error?.message || "Unexpected error."));
  }
}

// Option C puts the real Docker CLI and the real Compose plugin in front of
// whichever engine the host runs, so these checks probe the same things either
// way, and so do the CLI's own error strings. What changes is what an operator
// has to do about a failure: there is no Docker daemon to start on a Podman
// host, and rootful Podman's socket is root:root with no group to join until a
// podman.socket drop-in gives it one -- which is why the stock advice to read
// the group id back with stat is worse than useless there, reporting 0.
const ENGINE_REMEDIATION = {
  docker: {
    summary: "",
    cliMissing: {
      message: "Docker is missing.",
      detail: [
        "Run the included installer on the server so it can install Docker for you.",
        "If you use Docker Desktop, install and start Docker Desktop first."
      ]
    },
    composeMissing: {
      message: "Docker Compose is missing.",
      detail: ["Run the included installer again so it can add Compose where supported. If you use Docker Desktop, make sure Docker Desktop is fully started."]
    },
    socketMissing: {
      message: "Docker socket is not mounted.",
      detail: ["The Web UI container needs /var/run/docker.sock mounted so it can manage local Docker services."]
    },
    socketDenied: {
      message: "Docker socket permission denied.",
      intro: "The Web UI can see Docker, but this container cannot access the Docker socket.",
      detail: [
        "Set DOCKER_SOCKET_GID to the Docker socket group id, then restart the Web UI:",
        "  DOCKER_SOCKET_GID=$(stat -c '%g' /var/run/docker.sock) dune console restart"
      ]
    },
    notRunning: {
      message: "Docker daemon is not running or cannot be reached.",
      detail: [
        "Start Docker on the server, then restart the Web UI.",
        "On Linux, the included installer normally starts Docker automatically.",
        "If you use Docker Desktop, open Docker Desktop and wait until it says the engine is running."
      ]
    },
    unreachable: {
      message: "Docker is installed but is not running or cannot be reached.",
      detail: [
        "Run the included installer again so it can start Docker and repair access where supported.",
        "If you use Docker Desktop, open Docker Desktop and wait until it says the engine is running."
      ]
    }
  },
  podman: {
    summary: "The Docker CLI and the Compose plugin are talking to Podman's Docker-compatible API socket, so the checks below report on Podman.",
    cliMissing: {
      message: "The Docker CLI is missing.",
      detail: ["Run the included installer on the server so it can install the Docker CLI. Podman needs it: the CLI is what this stack drives, over Podman's Docker-compatible socket."]
    },
    composeMissing: {
      message: "Docker Compose is missing.",
      detail: ["Run the included installer again so it can add the Compose v2 plugin. Podman ships no Compose of its own, and podman-compose is not a substitute."]
    },
    socketMissing: {
      message: "The container engine socket is not mounted.",
      detail: [
        "The Web UI container needs Podman's API socket mounted at /var/run/docker.sock so it can manage local services.",
        "Enable the socket on the server first, then restart the Web UI:",
        "  sudo systemctl enable --now podman.socket"
      ]
    },
    socketDenied: {
      message: "Podman socket permission denied.",
      intro: "The Web UI can see the engine, but this container cannot access the socket mounted at /var/run/docker.sock.",
      detail: [
        "Rootful Podman's socket is owned by root:root, so a group id alone cannot grant access until the socket has a group. Give it one with a podman.socket drop-in (SocketGroup= and SocketMode=0660, plus an ExecStartPost= that opens /run/podman itself), then set DOCKER_SOCKET_GID to that group and restart the Web UI:",
        "  DOCKER_SOCKET_GID=$(stat -c '%g' /var/run/docker.sock) dune console restart",
        "Membership of that group is equivalent to root on this host; grant it as narrowly as the docker group."
      ]
    },
    notRunning: {
      message: "The Podman API socket is not running or cannot be reached.",
      detail: [
        "Start Podman's API socket on the server, then restart the Web UI:",
        "  sudo systemctl enable --now podman.socket",
        "Podman has no long-running daemon: if the socket is not enabled, nothing answers at /var/run/docker.sock."
      ]
    },
    unreachable: {
      message: "Podman is installed but its API socket is not running or cannot be reached.",
      detail: [
        "Run the included installer again so it can enable podman.socket and repair access where supported.",
        "  sudo systemctl status podman.socket"
      ]
    }
  }
};

const DEFAULT_SOCKET_PATH = "/var/run/docker.sock";

// Exported as a group so the engine-dependent checks can be exercised without a
// container engine, and without preflight()'s port probes.
export function engineChecks({ engine = containerEngine(), run = runEngineCommand, socketPath = DEFAULT_SOCKET_PATH } = {}) {
  const advice = ENGINE_REMEDIATION[engine.kind] || ENGINE_REMEDIATION.docker;
  return [
    check("Container engine", "info", engine.kind, advice.summary),
    dockerCliCheck(run, advice),
    dockerComposeCheck(run, advice),
    dockerSocketCheck(socketPath, advice),
    dockerDaemonCheck(run, advice, socketPath)
  ];
}

function runEngineCommand(args) {
  return execFileSync("docker", args, { encoding: "utf8", timeout: 5000, stdio: ["ignore", "pipe", "pipe"] });
}

function dockerCliCheck(run, advice) {
  try {
    return check("Docker CLI", "pass", run(["--version"]).split(/\r?\n/)[0]);
  } catch (error) {
    return check("Docker CLI", "fail", advice.cliMissing.message, advice.cliMissing.detail.join("\n"));
  }
}

function dockerComposeCheck(run, advice) {
  try {
    return check("Docker Compose", "pass", run(["compose", "version"]).split(/\r?\n/)[0]);
  } catch (error) {
    return check("Docker Compose", "fail", advice.composeMissing.message, advice.composeMissing.detail.join("\n"));
  }
}

function dockerDaemonCheck(run, advice, socketPath) {
  try {
    const out = run(["info"]);
    const line = out.split(/\r?\n/).map((part) => part.trim()).find(Boolean) || "Docker daemon is reachable";
    return check("Docker daemon", "pass", line);
  } catch (error) {
    const output = commandErrorOutput(error);
    if (/permission denied/i.test(output) && /docker\.sock|docker daemon/i.test(output)) {
      return check(
        "Docker daemon",
        "fail",
        advice.socketDenied.message,
        [
          advice.socketDenied.intro,
          dockerSocketDetail(null, socketPath),
          ...advice.socketDenied.detail
        ].filter(Boolean).join("\n")
      );
    }
    if (/cannot connect to the docker daemon|is the docker daemon running/i.test(output)) {
      return check("Docker daemon", "fail", advice.notRunning.message, advice.notRunning.detail.join("\n"));
    }
    return check("Docker daemon", "fail", advice.unreachable.message, [...advice.unreachable.detail, output].join("\n"));
  }
}

function dockerSocketCheck(socketPath, advice) {
  if (!existsSync(socketPath)) {
    return check("Docker socket", "fail", advice.socketMissing.message, advice.socketMissing.detail.join("\n"));
  }
  try {
    const st = statSync(socketPath);
    return check("Docker socket", st.isSocket() ? "pass" : "warn", dockerSocketDetail(st, socketPath));
  } catch (error) {
    return check("Docker socket", "fail", "Could not inspect Docker socket.", String(error?.message || "Unexpected error."));
  }
}

function dockerSocketDetail(existingStat = null, socketPath = DEFAULT_SOCKET_PATH) {
  try {
    const st = existingStat || statSync(socketPath);
    return `Socket group id: ${st.gid}, mode: ${modeString(st.mode)}`;
  } catch {
    return "";
  }
}

function commandErrorOutput(error) {
  return String(error?.stderr || error?.stdout || error?.message || "Unexpected error.").trim();
}

function modeString(mode) {
  return `0${(mode & 0o777).toString(8)}`;
}

function fileCheck(name, path, optional = false) {
  if (existsSync(path)) return check(name, "pass", path);
  return check(optional ? `${name} (setup will create this)` : name, optional ? "info" : "fail", optional ? "Not created yet" : `Missing: ${path}`, optional ? path : "");
}

function diskCheck(path) {
  try {
    const st = statSync(path);
    return check("Disk path", st.isDirectory() ? "pass" : "warn", path);
  } catch {
    return check("Disk path", "fail", path);
  }
}

function cpuFlags() {
  try {
    const text = readFileSync("/proc/cpuinfo", "utf8").toLowerCase();
    const avx = text.includes(" avx ");
    const avx2 = text.includes(" avx2 ");
    return check("CPU AVX/AVX2", avx && avx2 ? "pass" : "warn", `AVX=${avx ? "yes" : "no"}, AVX2=${avx2 ? "yes" : "no"}`);
  } catch {
    return check("CPU AVX/AVX2", "warn", "Could not read /proc/cpuinfo");
  }
}

async function portCheck(port) {
  return new Promise((resolveCheck) => {
    const server = createServer();
    server.once("error", () => resolveCheck(check(`Port ${port}`, "warn", "Already in use or unavailable")));
    server.once("listening", () => server.close(() => resolveCheck(check(`Port ${port}`, "pass", "Available"))));
    server.listen(port, "0.0.0.0");
  });
}

function gb(bytes) {
  return (bytes / 1024 ** 3).toFixed(1);
}
