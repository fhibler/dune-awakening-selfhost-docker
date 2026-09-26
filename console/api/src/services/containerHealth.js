import { execFile } from "node:child_process";
import { isAbsolute, relative, sep } from "node:path";
import { containerEngine } from "../engine.js";

const MAX_OUTPUT_BYTES = 1024 * 1024;

export async function collectContainerHealth(options = {}) {
  const projectName = String(options.projectName ?? process.env.DUNE_COMPOSE_PROJECT_NAME ?? process.env.COMPOSE_PROJECT_NAME ?? "").trim();
  if (!projectName) return { containers: [], error: "The Dune Compose project name is not configured." };

  const run = options.run || execFileText;
  const engine = options.engine || containerEngine();
  const hostRoot = String(options.hostRoot ?? process.env.DUNE_HOST_REPO_ROOT ?? "").trim();
  try {
    const rows = parseJsonLines(await run("docker", ["ps", "--all", "--no-trunc", "--format", "{{json .}}"]));
    if (!rows.length) return { containers: [] };
    // Inspect only ownership metadata, never Config.Env (which holds secrets).
    const ownership = parseJsonLines(await run("docker", ["inspect", "--format",
      '{"id":{{json .Id}},"labels":{{json .Config.Labels}},"mounts":{{json .Mounts}}}', ...rows.map(row => row.ID)]));
    const owned = new Set(ownership.filter(row => {
      if (row.labels?.["com.docker.compose.project"] === projectName) return true;
      return (row.mounts || []).some(mount => {
        if (mount.Type === "volume") return ["dune-server", "dune-steam", "dune-cache", "dune-generated", "dune-work"].some(name => mount.Name === `${projectName}_${name}`);
        if (mount.Type !== "bind" || !isAbsolute(hostRoot) || hostRoot === sep || !isAbsolute(mount.Source || "")) return false;
        const child = relative(hostRoot, mount.Source);
        return child === "" || (child !== ".." && !child.startsWith(`..${sep}`) && !isAbsolute(child));
      });
    }).map(row => row.id));
    const selected = rows.filter(row => owned.has(row.ID));
    const statusOutput = selected.map(row => JSON.stringify(row)).join("\n");
    const containerIds = selected.filter(row => row.State === "running").map(row => row.ID);
    if (!containerIds.length) return { containers: mergeContainerHealth("", statusOutput) };
    // Podman's compat endpoint answers a one-shot stats request with a single
    // sample and a zeroed precpu baseline, so the CLI's delta arithmetic
    // produces a percentage that describes nothing. Nothing errors, which is
    // what makes it dangerous: addons read these rows through
    // ops.health.containers and would conclude the host is idle. Memory and
    // I/O are instantaneous readings and stay trustworthy.
    const cpuFromStats = engine.kind !== "podman";

    // Resolve installation ownership first, then pass only running IDs so addons cannot
    // obtain telemetry for unrelated host containers.
    const statsOutput = await run("docker", ["stats", "--no-stream", "--format", "{{json .}}", ...containerIds]);
    return { containers: mergeContainerHealth(statsOutput, statusOutput, { cpuFromStats }) };
  } catch {
    return { containers: [], error: "Docker container statistics are unavailable." };
  }
}

export function mergeContainerHealth(statsOutput, statusOutput = "", { cpuFromStats = true } = {}) {
  const stats = new Map(parseJsonLines(statsOutput).map(row => [containerName(row), row]));
  return parseJsonLines(statusOutput)
    .map((status) => {
      const name = containerName(status);
      const row = status.State && status.State !== "running" ? {} : stats.get(name) || {};
      const [memory = "N/A", memoryLimit = "N/A"] = row.MemUsage ? String(row.MemUsage).split("/").map(value => value.trim()) : [];
      return {
        name,
        cpu: cpuFromStats ? String(row.CPUPerc || "N/A") : "N/A",
        memory,
        memoryLimit,
        networkIO: String(row.NetIO || "N/A"),
        blockIO: String(row.BlockIO || "N/A"),
        status: String(status.Status || "Unknown")
      };
    })
    .filter((row) => row.name)
    .sort((a, b) => a.name.localeCompare(b.name));
}

function parseJsonLines(output) {
  return String(output || "").split(/\r?\n/).map((line) => line.trim()).filter(Boolean).map((line) => JSON.parse(line));
}

function containerName(row) {
  return String(row?.Name || row?.Names || row?.Container || "").trim();
}

function execFileText(command, args) {
  return new Promise((resolve, reject) => {
    execFile(command, args, { encoding: "utf8", timeout: 5000, maxBuffer: MAX_OUTPUT_BYTES }, (error, stdout) => {
      if (error) reject(error);
      else resolve(stdout);
    });
  });
}
