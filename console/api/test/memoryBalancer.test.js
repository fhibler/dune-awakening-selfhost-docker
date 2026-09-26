import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
import { applyContainerSwapStats, collectContainerSwapStats, CONTAINER_SWAP_STAT_SCRIPT, createDockerStatsSampler, createMemoryBalancer, dockerMemoryUpdateArgs, parseContainerSwapStats, parseDockerStatsRow, readMemorySwapAllowanceBytes } from "../src/services/memoryBalancer.js";

test("memory balancer updates Docker swap limit with memory limit", () => {
  assert.deepEqual(dockerMemoryUpdateArgs("dune-server-overmap", 2 * 1024 ** 3), [
    "update",
    "--memory",
    "2048m",
    "--memory-swap",
    "4096m",
    "--memory-reservation",
    "2048m",
    "dune-server-overmap"
  ]);
});

test("memory balancer preserves the configured emergency swap allowance", () => {
  assert.deepEqual(dockerMemoryUpdateArgs("dune-server-overmap", 2 * 1024 ** 3, 2 * 1024 ** 3), [
    "update", "--memory", "2048m", "--memory-swap", "4096m", "--memory-reservation", "2048m", "dune-server-overmap"
  ]);
});

test("memory balancer reads only validated enabled swap settings", () => {
  const root = mkdtempSync(join(tmpdir(), "dune-memory-swap-env-"));
  writeFileSync(join(root, ".env"), "DUNE_MEMORY_SWAP_ENABLED=1\nDUNE_MEMORY_SWAP_PER_SERVER_GIB=2\n");
  assert.equal(readMemorySwapAllowanceBytes({ repoRoot: root }), 2 * 1024 ** 3);
  writeFileSync(join(root, ".env"), "DUNE_MEMORY_SWAP_ENABLED=0\nDUNE_MEMORY_SWAP_PER_SERVER_GIB=12\n");
  assert.equal(readMemorySwapAllowanceBytes({ repoRoot: root }), 0);
  rmSync(root, { recursive: true, force: true });
});

test("memory balancer parses docker stats rows", () => {
  const row = parseDockerStatsRow(JSON.stringify({
    Name: "dune-server-overmap",
    MemUsage: "1.5GiB / 2GiB",
    MemPerc: "75.00%"
  }));
  assert.equal(row.container, "dune-server-overmap");
  assert.equal(row.map, "Overmap");
  assert.equal(row.percent, 75);
});

test("memory balancer canonicalizes DeepDesert containers", () => {
  const row = parseDockerStatsRow(JSON.stringify({
    Name: "dune-server-deepdesert-1-8",
    MemUsage: "3GiB / 16GiB",
    MemPerc: "18.75%"
  }));
  assert.equal(row.container, "dune-server-deepdesert-1-8");
  assert.equal(row.map, "DeepDesert_1");
});

test("memory sampler parses cgroup v2 and v1 swap counters", () => {
  assert.deepEqual(parseContainerSwapStats("v2|2147483648|4294967296\n"), {
    supported: true,
    cgroupVersion: 2,
    usedBytes: 2 * 1024 ** 3,
    limitBytes: 4 * 1024 ** 3
  });
  assert.deepEqual(parseContainerSwapStats("v1|10737418240|12884901888|13958643712|16106127360\n"), {
    supported: true,
    cgroupVersion: 1,
    usedBytes: 2 * 1024 ** 3,
    limitBytes: 2 * 1024 ** 3
  });
  assert.equal(parseContainerSwapStats("v2|not-a-number|2147483648").supported, false);
});

test("live memory sampler enriches RAM rows with current container swap", async () => {
  const row = { container: "dune-server-overmap", usedBytes: 10 * 1024 ** 3, limitBytes: 13 * 1024 ** 3 };
  const sampler = createDockerStatsSampler({}, {
    collect: async () => [row],
    collectSwap: async () => new Map([[row.container, parseContainerSwapStats("v2|2147483648|2147483648")]])
  });
  const snapshot = await sampler.read();
  assert.equal(snapshot.rows[0].swapSupported, true);
  assert.equal(snapshot.rows[0].swapUsedBytes, 2 * 1024 ** 3);
  assert.equal(snapshot.rows[0].swapLimitBytes, 2 * 1024 ** 3);
});

test("swap collector is disabled with managed memory swap and ignores stopped-container races", async () => {
  const root = mkdtempSync(join(tmpdir(), "dune-memory-swap-sampler-"));
  const rows = [{ container: "dune-server-overmap" }, { container: "dune-server-survival-1" }];
  writeFileSync(join(root, ".env"), "DUNE_MEMORY_SWAP_ENABLED=0\n");
  let calls = 0;
  assert.equal((await collectContainerSwapStats({ repoRoot: root }, rows, { run: async () => { calls += 1; } })).size, 0);
  assert.equal(calls, 0);

  writeFileSync(join(root, ".env"), "DUNE_MEMORY_SWAP_ENABLED=1\nDUNE_MEMORY_SWAP_PER_SERVER_GIB=2\n");
  const collected = await collectContainerSwapStats({ repoRoot: root }, rows, { run: async (container) => {
    calls += 1;
    if (container.endsWith("survival-1")) throw new Error("container stopped");
    return "v2|1073741824|2147483648";
  } });
  assert.equal(calls, 2);
  assert.equal(collected.size, 1);
  assert.equal(collected.get("dune-server-overmap").usedBytes, 1024 ** 3);
  rmSync(root, { recursive: true, force: true });
});

test("swap enrichment leaves unsupported rows explicit instead of estimating", () => {
  const rows = applyContainerSwapStats([{ container: "dune-server-overmap", usedBytes: 1 }], new Map());
  assert.deepEqual(rows[0], {
    container: "dune-server-overmap",
    usedBytes: 1,
    swapUsedBytes: 0,
    swapLimitBytes: 0,
    swapSupported: false
  });
});

test("live memory sampler caches completed Docker stats collections", async () => {
  let currentTime = 1000;
  let collections = 0;
  const sampler = createDockerStatsSampler({}, {
    cacheMs: 10000,
    now: () => currentTime,
    collect: async () => [{ container: `sample-${++collections}` }]
  });

  const first = await sampler.read();
  currentTime += 5000;
  const cached = await sampler.read();
  assert.equal(collections, 1);
  assert.strictEqual(cached, first);

  currentTime += 5001;
  const refreshed = await sampler.read();
  assert.equal(collections, 2);
  assert.notStrictEqual(refreshed, first);
});

test("live memory sampler coalesces overlapping and forced collections", async () => {
  let release;
  let collections = 0;
  const sampler = createDockerStatsSampler({}, {
    collect: () => {
      collections += 1;
      return new Promise((resolve) => { release = resolve; });
    }
  });

  const first = sampler.read();
  const overlapping = sampler.read({ fresh: true });
  await Promise.resolve();
  assert.equal(collections, 1);
  release([{ container: "dune-server-overmap" }]);
  assert.strictEqual(await overlapping, await first);

  const forced = sampler.read({ fresh: true });
  await Promise.resolve();
  assert.equal(collections, 2);
  release([{ container: "dune-server-survival-1" }]);
  await forced;
});

test("memory balancer persists enabled state across restarts", async () => {
  const root = mkdtempSync(join(tmpdir(), "dune-memory-balancer-"));
  const generatedDir = join(root, "runtime/generated");
  mkdirSync(generatedDir, { recursive: true });
  writeFileSync(join(generatedDir, "memory-balancer.json"), JSON.stringify({ enabled: true }));

  const balancer = createMemoryBalancer({ repoRoot: root, generatedDir });
  assert.equal(balancer.publicState().enabled, true);

  await balancer.setEnabled(false);
  assert.equal(JSON.parse(readFileSync(join(generatedDir, "memory-balancer.json"), "utf8")).enabled, false);

  rmSync(root, { recursive: true, force: true });
});

test("container swap sampler script is valid POSIX shell", () => {
  execFileSync("/bin/sh", ["-n", "-c", CONTAINER_SWAP_STAT_SCRIPT], { stdio: ["ignore", "ignore", "pipe"] });
});

// The sampler resolves /proc/self/cgroup before reading, because Podman may
// hand a container the host cgroup namespace, where the unprefixed files hold
// the host's swap totals. Under the private namespace Docker always gives --
// which is what this process has -- resolution must be a no-op.
test("container swap sampler reads the cgroup root unchanged under a private cgroup namespace", (t) => {
  let expected;
  try {
    if (readFileSync("/proc/self/cgroup", "utf8").trim() !== "0::/") return t.skip("not a private cgroup v2 namespace");
    expected = ["current", "max"].map((name) => readFileSync(`/sys/fs/cgroup/memory.swap.${name}`, "utf8").trim());
  } catch {
    return t.skip("cgroup v2 swap accounting is unavailable on this host");
  }
  const output = execFileSync("/bin/sh", ["-c", CONTAINER_SWAP_STAT_SCRIPT], { encoding: "utf8" });
  assert.equal(output.trim(), `v2|${expected[0]}|${expected[1]}`);
  assert.deepEqual(parseContainerSwapStats(output).supported, true);
});
