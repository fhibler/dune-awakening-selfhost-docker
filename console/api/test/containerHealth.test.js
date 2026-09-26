import assert from "node:assert/strict";
import test from "node:test";
import { collectContainerHealth, mergeContainerHealth } from "../src/services/containerHealth.js";

test("container health parses and joins Docker stats with real status output", () => {
  const result = mergeContainerHealth(
    '{"Name":"dune-postgres","CPUPerc":"1.2%","MemUsage":"100MiB / 1GiB","NetIO":"1kB / 2kB","BlockIO":"3MB / 4MB"}\n',
    '{"Names":"dune-postgres","Status":"Up 2 hours (healthy)"}\n'
  );
  assert.deepEqual(result, [{
    name: "dune-postgres",
    cpu: "1.2%",
    memory: "100MiB",
    memoryLimit: "1GiB",
    networkIO: "1kB / 2kB",
    blockIO: "3MB / 4MB",
    status: "Up 2 hours (healthy)"
  }]);
});

test("container health includes Compose and host-mounted Dune services but excludes unrelated installations", async () => {
  const calls = [];
  const result = await collectContainerHealth({
    projectName: "dune-test",
    hostRoot: "/srv/dune",
    run: async (command, args) => {
      calls.push({ command, args });
      if (args[0] === "ps") {
        return [
          '{"ID":"abc123","Names":"dune-postgres","State":"running","Status":"Up 2 hours (healthy)"}',
          '{"ID":"def456","Names":"dune-director","State":"running","Status":"Up 1 hour"}',
          '{"ID":"stopped","Names":"dune-server-deepdesert-1-35","State":"exited","Status":"Exited (1) 2 hours ago"}',
          '{"ID":"other","Names":"dune-unrelated","State":"running","Status":"Up 1 hour"}'
        ].join("\n");
      }
      if (args[0] === "inspect") return [
        { id: "abc123", labels: { "com.docker.compose.project": "dune-test" } },
        { id: "def456", mounts: [{ Type: "bind", Source: "/srv/dune/runtime/director" }] },
        { id: "stopped", mounts: [{ Type: "bind", Source: "/srv/dune/runtime/game/dd/Saved" }] },
        { id: "other", labels: { "com.docker.compose.project": "other" }, mounts: [{ Type: "bind", Source: "/srv/dune-other/runtime" }] }
      ].map(row => JSON.stringify(row)).join("\n");
      return [
        '{"Name":"dune-postgres","CPUPerc":"1.2%","MemUsage":"100MiB / 1GiB"}',
        '{"Name":"dune-director","CPUPerc":"0.2%","MemUsage":"50MiB / 1GiB"}'
      ].join("\n");
    }
  });
  assert.equal(result.containers.length, 3);
  assert.equal(result.containers.find(row => row.name.includes("deepdesert")).status, "Exited (1) 2 hours ago");
  assert.equal(result.containers.find(row => row.name.includes("deepdesert")).cpu, "N/A");
  assert.equal(calls.length, 3);
  assert.deepEqual(calls[0], {
    command: "docker",
    args: ["ps", "--all", "--no-trunc", "--format", "{{json .}}"]
  });
  assert.deepEqual(calls[2], {
    command: "docker",
    args: ["stats", "--no-stream", "--format", "{{json .}}", "abc123", "def456"]
  });
});

test("container health does not call Docker stats when the Compose project has no running containers", async () => {
  const calls = [];
  const result = await collectContainerHealth({
    projectName: "dune-test",
    run: async (command, args) => {
      calls.push({ command, args });
      return "";
    }
  });
  assert.deepEqual(result, { containers: [] });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].args[0], "ps");
});

test("container health fails closed instead of exposing every host container", async () => {
  let called = false;
  const result = await collectContainerHealth({ projectName: "", run: async () => { called = true; return ""; } });
  assert.equal(called, false);
  assert.deepEqual(result.containers, []);
  assert.match(result.error, /project name/i);
});

test("stopped installation volumes are listed without requesting statistics", async () => {
  const calls = [];
  const result = await collectContainerHealth({
    projectName: "dune-test", hostRoot: "",
    run: async (_command, args) => {
      calls.push(args[0]);
      if (args[0] === "ps") return JSON.stringify({ ID: "a", Names: "dune-server", State: "exited", Status: "Exited (0)" });
      if (args[0] === "inspect") return JSON.stringify({ id: "a", mounts: [{ Type: "volume", Name: "dune-test_dune-server" }] });
      throw new Error("Stopped containers must not receive a stats request");
    }
  });
  assert.deepEqual(calls, ["ps", "inspect"]);
  assert.equal(result.containers[0].status, "Exited (0)");
  assert.equal(result.containers[0].memory, "N/A");
});

test("running containers remain visible if Docker stats omits them", () => {
  const result = mergeContainerHealth("", JSON.stringify({ Names: "dune-director", State: "running", Status: "Up 1 minute" }));
  assert.equal(result.length, 1);
  assert.equal(result[0].status, "Up 1 minute");
  assert.equal(result[0].cpu, "N/A");
});

test("container health withholds Podman's single-sample CPU percentage instead of reporting it", async () => {
  const calls = [];
  const run = async (command, args) => {
    calls.push(args);
    if (args[0] === "ps") return '{"ID":"abc123","Names":"dune-postgres","State":"running","Status":"Up 2 hours (healthy)"}';
    if (args[0] === "inspect") return JSON.stringify({ id: "abc123", labels: { "com.docker.compose.project": "dune-test" } });
    // What Podman's compat endpoint yields for a one-shot request: a single
    // sample against a zeroed baseline, so the CLI's delta is meaningless.
    return '{"Name":"dune-postgres","CPUPerc":"0.00%","MemUsage":"100MiB / 1GiB","NetIO":"1kB / 2kB","BlockIO":"3MB / 4MB"}';
  };

  const podman = await collectContainerHealth({ projectName: "dune-test", run, engine: { kind: "podman" } });
  assert.deepEqual(podman.containers, [{
    name: "dune-postgres",
    cpu: "N/A",
    memory: "100MiB",
    memoryLimit: "1GiB",
    networkIO: "1kB / 2kB",
    blockIO: "3MB / 4MB",
    status: "Up 2 hours (healthy)"
  }]);
  // Same request either way: only the reading of the answer differs.
  assert.deepEqual(calls[2], ["stats", "--no-stream", "--format", "{{json .}}", "abc123"]);

  const docker = await collectContainerHealth({ projectName: "dune-test", run, engine: { kind: "docker" } });
  assert.equal(docker.containers[0].cpu, "0.00%");
});
