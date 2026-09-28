import test from "node:test";
import assert from "node:assert/strict";
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  buildHeartbeatPayload,
  collectPlayerPortalContext,
  collectPlayerPortalClientConfiguration,
  collectDirectorySnapshot,
  createPublicDirectoryReporter,
  getOrCreateIdentity,
  isBattlegroupRunning,
  normalizeDiscordInvite,
  playerPortalMapSnapshot,
  playerPortalSnapshotBatches,
  readConfiguredCapacity,
  recoverRunningDirectorCapacity,
  readDirectoryInstallationKey,
  readPreviousDirectoryInstallationKey,
  readPublicModifierMetadata,
  readPublicModifiers,
  readDirectorySettings,
  readGameBuild,
  reconcilePublicProbe
} from "../src/services/publicDirectory.js";

test("player portal context exposes only player-safe server policy and notice fields", () => {
  const files = fixture();
  try {
    writeFileSync(join(files.generatedDir, "message-of-the-day.json"), JSON.stringify({ enabled: true, title: "Welcome", message: "Mind the sandworms." }));
    writeFileSync(join(files.generatedDir, "restart-schedule.env"), "DUNE_SCHEDULED_RESTART_ENABLED=1\nDUNE_SCHEDULED_RESTART_TIME=05:30\nDUNE_SCHEDULED_RESTART_NOTIFY_MINUTES=20\n");
    writeFileSync(join(files.generatedDir, "care-package.json"), JSON.stringify({ enabled: true, kits: [] }));
    writeFileSync(join(files.generatedDir, "sietch-config.json"), JSON.stringify({ partitions: { "1": { map: "Survival_1", dimension: 0, display_name: "Sietch New" } } }));
    const context = collectPlayerPortalContext({ repoRoot: files.repoRoot, generatedDir: files.generatedDir }, { running: true, ready: true, playersOnline: 3, capacity: 40, sietches: 2, version: "1.2.3" });
    assert.equal(context.serverInfo.messageOfTheDay.message, "Mind the sandworms.");
    assert.equal(context.serverInfo.restart.localTime, "05:30");
    assert.equal(context.serverInfo.transfers.outgoingAllowed, true);
    assert.equal(context.carePackages.enabled, true);
    assert.deepEqual(context.sietchNames, { "1": "Sietch New" });
    assert.equal(JSON.stringify(context).includes("path"), false);
  } finally {
    files.cleanup();
  }
});

test("player portal client configuration uses generated allowlisted INIs and rejects secrets", async () => {
  const calls = [];
  const runner = async (_config, args) => {
    calls.push(args);
    return { stdout: args.includes("client-game-ini") ? "; safe\n[/Script/DuneSandbox.DuneGameMode]\nm_WaterConsumptionRate=2\n" : "; safe\n[ConsoleVariables]\nfoo=bar\n" };
  };
  const result = await collectPlayerPortalClientConfiguration({ repoRoot: "/repo" }, runner);
  assert.equal(result.available, true);
  assert.match(result.installPath, /Windows$/);
  assert.match(result.gameInstallPath, /Windows$/);
  assert.match(result.engineInstallPath, /Windows$/);
  assert.match(result.gameIni, /m_WaterConsumptionRate=2/);
  assert.equal(calls.length, 2);

  const unsafe = await collectPlayerPortalClientConfiguration({}, async () => ({ stdout: "ServerPassword=hunter2\n" }));
  assert.equal(unsafe.available, false);
  assert.match(unsafe.gameInstallPath, /Windows$/);
  assert.match(unsafe.engineInstallPath, /Windows$/);
  assert.equal(unsafe.gameIni, "");
});

test("large private portal snapshots are split below the website request limit", () => {
  const observedAt = "2026-08-19T12:00:00.000Z";
  const snapshots = Array.from({ length: 4 }, (_, index) => ({ accountHash: String(index).padStart(64, "a"), found: true, data: { storage: { payload: "x".repeat(300) } } }));
  const batches = playerPortalSnapshotBatches(snapshots, observedAt, 700);
  assert.ok(batches.length > 1);
  assert.equal(batches.flat().length, snapshots.length);
  for (const batch of batches) assert.ok(Buffer.byteLength(JSON.stringify({ observedAt, snapshots: batch })) <= 700 || batch.length === 1);
});

test("player portal map snapshots contain world layers but no private actors", async () => {
  const result = await playerPortalMapSnapshot({}, {}, {
    fetchPoi: async (_db, map) => ({
      capabilities: { ore: true },
      knownSubtypes: { ore: ["JasmiumOre", "StravidiumOre", "TitaniumOre"] },
      subtypeLabels: { ore: { JasmiumOre: "Jasmium", StravidiumOre: "Stravidium", TitaniumOre: "Titanium" } },
      rows: [
        { id: "ore-1", type: "ore", name: "TitaniumOre", map, x: 10, y: 20, z: 30, ...(map === "DeepDesert" ? { sector: "E5" } : {}) },
        { id: "player-2", type: "player", name: "Other Player", map, x: 40, y: 50, z: 60, owner_name: "Private" }
      ]
    }),
    fetchSpice: async (_db, map) => ({
      capabilities: { spice_active: true },
      currentSeed: "7",
      nextCycleAt: "2026-08-29T05:00:00.000Z",
      rows: [{ id: "spice-1", type: "spice_active", name: "Active Large Spice", map, partition_id: 31, x: 70, y: 80 }]
    }),
    fetchPartitions: async () => ({ rows: [{ map: "DeepDesert", partition_id: 31, name: "Deep Desert 1", marker_count: 99 }] })
  });

  assert.ok(result.rows.some((row) => row.type === "ore"));
  assert.ok(result.rows.some((row) => row.type === "spice_active"));
  assert.ok(result.rows.some((row) => row.type === "ore" && row.map === "DeepDesert" && row.sector === "E5"));
  assert.equal(result.rows.some((row) => row.type === "player"), false);
  assert.equal(JSON.stringify(result).includes("Other Player"), false);
  assert.equal(JSON.stringify(result).includes("owner_name"), false);
  assert.deepEqual(result.partitions, [{ map: "DeepDesert", partitionId: 31, name: "Deep Desert 1" }]);
  assert.equal(result.cycles.DeepDesert.coriolisSeed, "7");
  assert.deepEqual(result.knownSubtypes.ore, ["JasmiumOre", "StravidiumOre", "TitaniumOre"]);
  assert.equal(result.subtypeLabels.ore.TitaniumOre, "Titanium");
});

test("player portal map snapshots exclude owner-disabled world layers before upload", async () => {
  const result = await playerPortalMapSnapshot({}, {}, {
    allowedTypes: ["poi"],
    fetchPoi: async (_db, map) => ({
      capabilities: { ore: true, poi: true },
      knownSubtypes: { ore: ["TitaniumOre"], poi: ["Ecolab"] },
      subtypeLabels: { ore: { TitaniumOre: "Titanium" }, poi: { Ecolab: "Ecology Lab" } },
      rows: [
        { id: "ore-1", type: "ore", name: "TitaniumOre", map, x: 10, y: 20 },
        { id: "poi-1", type: "poi", name: "Ecolab", map, x: 30, y: 40 }
      ]
    }),
    fetchSpice: async () => ({ capabilities: { spice_active: true }, rows: [] }),
    fetchPartitions: async () => ({ rows: [] })
  });
  assert.ok(result.rows.length > 0);
  assert.equal(result.rows.every((row) => row.type === "poi"), true);
  assert.deepEqual(result.capabilities, { poi: true });
  assert.deepEqual(result.knownSubtypes, { poi: ["Ecolab"] });
  assert.equal(JSON.stringify(result).includes("Titanium"), false);
});

test("player portal map partitions use configured Sietch display names", async () => {
  const files = fixture();
  try {
    writeFileSync(join(files.generatedDir, "sietch-config.json"), JSON.stringify({
      partitions: {
        "1": { map: "Survival_1", dimension: 0, label: "Abbir", display_name: "Sietch New" }
      }
    }));
    const result = await playerPortalMapSnapshot({ repoRoot: files.repoRoot }, {}, {
      fetchPoi: async () => ({ capabilities: {}, rows: [] }),
      fetchSpice: async () => ({ capabilities: {}, rows: [] }),
      fetchPartitions: async () => ({ rows: [{ map: "HaggaBasin", partition_id: 1, name: "Abbir" }] })
    });
    assert.deepEqual(result.partitions, [{ map: "HaggaBasin", partitionId: 1, name: "Sietch New" }]);
  } finally {
    files.cleanup();
  }
});

test("public modifier reporting is allowlisted and omits defaults and secrets", () => {
  const files = fixture();
  const path = join(files.generatedDir, "gameplay-profile.ini");
  try {
    writeFileSync(path, [
      "[Engine:ConsoleVariables]",
      "Dune.GlobalMiningOutputMultiplier=7.77",
      "Dune.GlobalVehicleMiningOutputMultiplier=1.000000",
      "Bgd.ServerLoginPassword=must-not-leak",
      "Unknown.PrivateSetting=42",
      "Sandstorm.Enabled=0",
      "",
      "[Partition:Survival_1:1:/Script/DuneSandbox.DuneGameMode]",
      "m_WaterConsumptionRate=0.5",
      "m_DefaultReconnectGracePeriodSeconds=600",
      "",
      "[Global:/Script/DuneSandbox.BuildingSettings]",
      "m_PickupTotalDurabilityPercentageReduction=0.25",
      "m_bBuildingRestrictionLimitsEnabled=False",
      "",
      "[Global:/Script/DuneSandbox.ContractsSubsystem]",
      "m_bIsEnabled=invalid"
    ].join("\n"));
    assert.deepEqual(readPublicModifiers(path), {
      "Mining Output": "7.77x",
      Sandstorms: "Disabled",
      "Water Consumption": "0.5x",
      "Reconnect Grace Period": "10 minutes",
      "Building Restriction Limits": "Disabled",
      "Building Pickup Durability Loss": "25%"
    });
  } finally {
    files.cleanup();
  }
});

test("public modifier reporting ignores retired unsupported modifiers", () => {
  const files = fixture();
  const path = join(files.generatedDir, "gameplay-profile.ini");
  try {
    writeFileSync(path, [
      "[Partition:Survival_1:1:/Script/DuneSandbox.DuneGameMode]",
      "m_GlobalXPMultiplier=2",
      "",
      "[Partition:Survival_1:2:/Script/DuneSandbox.DuneGameMode]",
      "m_GlobalXPMultiplier=3.0",
      "",
      "[Partition:Survival_1:3:/Script/DuneSandbox.DuneGameMode]",
      "m_GlobalXPMultiplier=1.000000"
    ].join("\n"));
    assert.deepEqual(readPublicModifiers(path), {});
  } finally {
    files.cleanup();
  }
});

test("public modifier reporting converts the augment roll threshold to jackpot chance", () => {
  const files = fixture();
  const path = join(files.generatedDir, "gameplay-profile.ini");
  try {
    writeFileSync(path, [
      "[Global:/Script/DuneSandbox.AugmentSettings]",
      "m_JackpotRollPercentage=0.75",
      "",
      "[Partition:Survival_1:1:/Script/DuneSandbox.AugmentSettings]",
      "m_JackpotRollPercentage=0.50"
    ].join("\n"));
    assert.deepEqual(readPublicModifiers(path), {
      "Augment Jackpot Chance": "Varies: 25%, 50%"
    });
  } finally {
    files.cleanup();
  }
});

test("public modifier reporting identifies invalid augment roll thresholds", () => {
  const files = fixture();
  const path = join(files.generatedDir, "gameplay-profile.ini");
  try {
    writeFileSync(path, [
      "[Global:/Script/DuneSandbox.AugmentSettings]",
      "m_JackpotRollPercentage=75",
      "",
      "[Partition:Survival_1:1:/Script/DuneSandbox.AugmentSettings]",
      "m_JackpotRollPercentage=100"
    ].join("\n"));
    assert.deepEqual(readPublicModifiers(path), {
      "Augment Jackpot Chance": "Varies: 75 (invalid; use 0–1), 100 (invalid; use 0–1)"
    });
  } finally {
    files.cleanup();
  }
});

test("public modifier reporting includes scoped UserEngine overrides", () => {
  const files = fixture();
  const path = join(files.generatedDir, "gameplay-profile.ini");
  try {
    writeFileSync(path, [
      "[Global:/Script/DuneSandbox.SpiceAddictionSubsystem]",
      "m_bIsSpiceAddictionEnabled=False",
      "",
      "[MapEngine:Survival_1:ConsoleVariables]",
      "Sandstorm.Enabled=0",
      "",
      "[PartitionEngine:DeepDesert_1:8:ConsoleVariables]",
      "sandworm.dune.Enabled=0"
    ].join("\n"));
    assert.deepEqual(readPublicModifiers(path), {
      Sandstorms: "Disabled",
      Sandworms: "Disabled",
      "Spice Addiction": "Disabled"
    });
  } finally {
    files.cleanup();
  }
});

test("public modifier metadata preserves scope and uses public instance names", () => {
  const files = fixture();
  const path = join(files.generatedDir, "gameplay-profile.ini");
  try {
    writeFileSync(join(files.generatedDir, "sietch-config.json"), JSON.stringify({
      maps: {
        Survival_1: {
          dimensions: {
            0: { display_name: "Sietch New", password: "must-not-leak" }
          }
        }
      },
      partitions: {
        1: {
          map: "Survival_1",
          dimension: 0,
          display_name: "Sietch New",
          password: "must-not-leak"
        },
        8: {
          map: "DeepDesert_1",
          dimension: 0,
          display_name: "Deep Desert PvE",
          password: "also-must-not-leak"
        }
      }
    }));
    writeFileSync(path, [
      "[Engine:ConsoleVariables]",
      "Dune.GlobalMiningOutputMultiplier=2.5",
      "",
      "[Partition:Survival_1:1:/Script/DuneSandbox.DuneGameMode]",
      "m_WaterConsumptionRate=0.5",
      "",
      "[Partition:Survival_1:2:/Script/DuneSandbox.DuneGameMode]",
      "m_WaterConsumptionRate=0.75",
      "",
      "[PartitionEngine:DeepDesert_1:8:ConsoleVariables]",
      "sandworm.dune.Enabled=0"
    ].join("\n"));

    const metadata = readPublicModifierMetadata(path, { repoRoot: files.repoRoot });
    assert.deepEqual(metadata.modifiers, {
      "Mining Output": "2.5x",
      "Water Consumption": "Varies: 0.5x, 0.75x",
      Sandworms: "Disabled"
    });
    assert.deepEqual(metadata.modifierGroups, [
      { scope: "global", map: "", partitionId: null, dimension: null, label: "Global", modifiers: { "Mining Output": "2.5x" } },
      { scope: "partition", map: "Survival_1", partitionId: 1, dimension: 0, label: "Sietch New", modifiers: { "Water Consumption": "0.5x" } },
      { scope: "partition", map: "Survival_1", partitionId: 2, dimension: null, label: "Sietch Partition 2", modifiers: { "Water Consumption": "0.75x" } },
      { scope: "partition", map: "DeepDesert_1", partitionId: 8, dimension: 0, label: "Deep Desert PvE", modifiers: { Sandworms: "Disabled" } }
    ]);
    assert.equal(JSON.stringify(metadata).includes("must-not-leak"), false);
  } finally {
    files.cleanup();
  }
});

test("heartbeat includes an empty Discord invite so stale directory links are removed", () => {
  const payload = buildHeartbeatPayload(
    { serverId: "server-id", secret: "secret" },
    {
      name: "Test Sietch",
      region: "Europe",
      running: true,
      ready: true,
      playersOnline: 0,
      capacity: 60,
      version: "2036754",
      sietches: 1,
      discordInvite: ""
    }
  );

  assert.equal(Object.hasOwn(payload, "discordInvite"), true);
  assert.equal(payload.discordInvite, "");
});

function fixture() {
  const repoRoot = mkdtempSync(join(tmpdir(), "dune-directory-"));
  const generatedDir = join(repoRoot, "runtime", "generated");
  const secretsDir = join(repoRoot, "runtime", "secrets");
  mkdirSync(join(repoRoot, "runtime", "director", "config"), { recursive: true });
  mkdirSync(generatedDir, { recursive: true });
  mkdirSync(secretsDir, { recursive: true });
  writeFileSync(join(repoRoot, ".env"), [
    'SERVER_TITLE="Test Sietch"',
    "SERVER_REGION=Europe Test",
    "SERVER_IP_MODE=public",
    "BATTLEGROUP_ID=sh-testbattlegroup-directory",
    "DUNE_PUBLIC_DIRECTORY_DISCORD_INVITE=https://discord.com/invite/Test_Code"
  ].join("\n"));
  writeFileSync(join(generatedDir, "image-tags.env"), "DUNE_WORLD_IMAGE_TAG=2036754-0-shipping\n");
  writeFileSync(join(generatedDir, "sietch-config.json"), JSON.stringify({
    maps: { Survival_1: { active_dimensions: 2 } }
  }));
  writeFileSync(join(repoRoot, "runtime", "director", "config", "director_config.ini"), [
    "[Server]",
    "PlayerHardCap=60",
    "ShouldUpdatePlayerCountOnFls=true",
    "[Survival_1]",
    "PlayerHardCap=60",
    "ShouldUpdatePlayerCountOnFls=true",
    "[Overmap]",
    "PlayerHardCap=80",
    "ShouldUpdatePlayerCountOnFls=false"
  ].join("\n"));
  return {
    repoRoot,
    generatedDir,
    secretsDir,
    cleanup: () => rmSync(repoRoot, { recursive: true, force: true })
  };
}

function fakeDb() {
  return {
    async query(sql) {
      if (sql.includes("to_regclass")) return { rows: [{ exists: true }] };
      if (sql.includes("sum(coalesce(connected_players")) return { rows: [{ players: 4 }] };
      if (sql.includes("from dune.player_state")) return { rows: [{ players: 3 }] };
      if (sql.includes("ready_maps")) {
        assert.match(sql, /fs\.alive/, "directory readiness must reject core maps that stopped reporting");
        return { rows: [{ ready_maps: 2 }] };
      }
      if (sql.includes("as sietches")) return { rows: [{ sietches: 9 }] };
      throw new Error(`Unexpected SQL: ${sql}`);
    }
  };
}

function response(body = {}, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    text: async () => JSON.stringify(body)
  };
}

test("directory settings default public servers on and normalize test regions", () => {
  const files = fixture();
  try {
    assert.deepEqual(readDirectorySettings(files.repoRoot, {}), {
      enabled: true,
      anonymousCountEnabled: true,
      mode: "public",
      title: "Test Sietch",
      region: "Europe",
      discordInvite: "https://discord.gg/Test_Code"
    });
    writeFileSync(join(files.repoRoot, ".env"), "SERVER_IP_MODE=public\nDUNE_PUBLIC_DIRECTORY_ENABLED=false\nDUNE_ANONYMOUS_SERVER_COUNT_ENABLED=false\n");
    assert.equal(readDirectorySettings(files.repoRoot, {}).enabled, false);
    assert.equal(readDirectorySettings(files.repoRoot, {}).anonymousCountEnabled, false);
  } finally {
    files.cleanup();
  }
});

test("saved directory opt-out overrides a stale container environment value", () => {
  const files = fixture();
  try {
    writeFileSync(join(files.repoRoot, ".env"), [
      "SERVER_IP_MODE=public",
      "SERVER_TITLE=Test",
      "SERVER_REGION=Europe",
      "DUNE_PUBLIC_DIRECTORY_ENABLED=true"
    ].join("\n"));
    assert.equal(readDirectorySettings(files.repoRoot, { DUNE_PUBLIC_DIRECTORY_ENABLED: "false" }).enabled, true);
  } finally {
    files.cleanup();
  }
});

test("directory snapshot uses compact database aggregates and local metadata", async () => {
  const files = fixture();
  try {
    const snapshot = await collectDirectorySnapshot(
      { repoRoot: files.repoRoot },
      fakeDb(),
      readDirectorySettings(files.repoRoot, {})
    );
    assert.deepEqual(snapshot, {
      name: "Test Sietch",
      region: "Europe",
      running: true,
      ready: true,
      playersOnline: 4,
      capacity: 120,
      capacityConfirmed: true,
      version: "2036754",
      installationKey: readDirectoryInstallationKey(files.repoRoot),
      previousInstallationKey: "",
      sietches: 2,
      sietchesConfirmed: true,
      discordInvite: "https://discord.gg/Test_Code",
      publicMetadata: {
        modifiers: {},
        modifierGroups: [],
        progression: { characters: 0, averageLevel: 0, highestLevel: 0 },
        transfers: {
          incomingPolicy: 0,
          outgoingAllowed: true,
          freeFrom: true,
          freeTo: true,
          worldClosed: false,
          worldClosingSoon: false
        }
      }
    });
    assert.equal(readGameBuild(files.repoRoot), "2036754");
    assert.equal(readConfiguredCapacity(files.repoRoot), 120);
    assert.equal(readConfiguredCapacity(files.repoRoot, 1), 60);
  } finally {
    files.cleanup();
  }
});

test("directory snapshot publishes only the public character transfer rules", async () => {
  const files = fixture();
  try {
    writeFileSync(join(files.generatedDir, "director-character-transfer.ini"), [
      "[Battlegroup]",
      "AcceptOutgoingCharacterTransfers=false",
      "IncomingCharacterTransfers=20",
      "FreeToTransferCharactersFrom=true",
      "FreeToTransferCharactersTo=false",
      "ForceIsWorldClosed=false",
      "ForceIsWorldClosingSoon=true",
      "ExportCharacterTimeout=1234"
    ].join("\n"));
    const snapshot = await collectDirectorySnapshot(
      { repoRoot: files.repoRoot },
      fakeDb(),
      readDirectorySettings(files.repoRoot, {})
    );
    assert.deepEqual(snapshot.publicMetadata.transfers, {
      incomingPolicy: 20,
      outgoingAllowed: false,
      freeFrom: true,
      freeTo: false,
      worldClosed: false,
      worldClosingSoon: true
    });
    assert.equal(JSON.stringify(snapshot.publicMetadata).includes("1234"), false);
  } finally {
    files.cleanup();
  }
});

test("configured Sietch capacity respects custom caps and active dimensions", () => {
  const files = fixture();
  try {
    writeFileSync(join(files.repoRoot, "runtime", "director", "config", "director_config.ini"), [
      "[Server]",
      "PlayerHardCap=40",
      "ShouldUpdatePlayerCountOnFls=false",
      "[Survival_1]",
      "PlayerHardCap=45",
      "ShouldUpdatePlayerCountOnFls=true",
      "[Overmap]",
      "PlayerHardCap=80",
      "ShouldUpdatePlayerCountOnFls=false"
    ].join("\n"));
    assert.equal(readConfiguredCapacity(files.repoRoot, 3), 135);
  } finally {
    files.cleanup();
  }
});

test("missing or incomplete director configuration is not reported as a real 60-player capacity", () => {
  const files = fixture();
  try {
    const path = join(files.repoRoot, "runtime", "director", "config", "director_config.ini");
    rmSync(path);
    assert.equal(readConfiguredCapacity(files.repoRoot, 3), null);

    writeFileSync(path, [
      "[Server]",
      "PlayerHardCap=60",
      "ShouldUpdatePlayerCountOnFls=false",
      "[Survival_1]"
    ].join("\n"));
    assert.equal(readConfiguredCapacity(files.repoRoot, 3), null);
  } finally {
    files.cleanup();
  }
});

test("capacity falls back to the persisted secret-free Director snapshot", () => {
  const files = fixture();
  try {
    rmSync(join(files.repoRoot, "runtime", "director", "config", "director_config.ini"));
    writeFileSync(join(files.generatedDir, "director-capacity.ini"), [
      "[Server]",
      "PlayerHardCap=40",
      "ShouldUpdatePlayerCountOnFls=false",
      "[Survival_1]",
      "PlayerHardCap=55",
      "ShouldUpdatePlayerCountOnFls=true"
    ].join("\n"));
    assert.equal(readConfiguredCapacity(files.repoRoot, 3), 165);
  } finally {
    files.cleanup();
  }
});

test("capacity recovers from a running Director and persists only filtered fields", async () => {
  const files = fixture();
  const calls = [];
  try {
    rmSync(join(files.repoRoot, "runtime", "director", "config", "director_config.ini"));
    const capacity = await recoverRunningDirectorCapacity(files.repoRoot, 2, async (file, args) => {
      calls.push({ file, args });
      return [
        "[Server]",
        "PlayerHardCap=40",
        "ShouldUpdatePlayerCountOnFls=false",
        "[Survival_1]",
        "PlayerHardCap=60",
        "ShouldUpdatePlayerCountOnFls=true"
      ].join("\n");
    });
    assert.equal(capacity, 120);
    assert.equal(calls[0].file, "docker");
    assert.deepEqual(calls[0].args.slice(0, 3), ["exec", "dune-director", "awk"]);
    const snapshotPath = join(files.generatedDir, "director-capacity.ini");
    assert.equal(readConfiguredCapacity(files.repoRoot, 2), 120);
    assert.equal(statSync(snapshotPath).mode & 0o777, 0o600);
    assert.doesNotMatch(readFileSync(snapshotPath, "utf8"), /Secret|Password|Token/i);
  } finally {
    files.cleanup();
  }
});

test("reporter recovers a missing capacity source without suppressing the heartbeat", async () => {
  const files = fixture();
  const payloads = [];
  try {
    rmSync(join(files.repoRoot, "runtime", "director", "config", "director_config.ini"));
    const reporter = createPublicDirectoryReporter({
      repoRoot: files.repoRoot,
      generatedDir: files.generatedDir,
      secretsDir: files.secretsDir
    }, {
      db: fakeDb(),
      getBattlegroupRunning: () => true,
      recoverRunningDirectorCapacity: async (_repoRoot, sietches) => 60 * sietches,
      fetchImpl: async (url, options) => {
        if (url.endsWith("/heartbeat")) payloads.push(JSON.parse(options.body));
        if (url.endsWith("/claim-status")) return response({ ok: true, claimed: false });
        return response({ ok: true, nextHeartbeatSeconds: 60 });
      },
      setTimeoutFn: () => ({ unref() {} })
    });
    await reporter.tick();
    assert.equal(payloads.length, 1);
    assert.equal(payloads[0].capacity, 120);
    assert.equal(reporter.publicState().state, "online");
  } finally {
    files.cleanup();
  }
});

test("reporter retains confirmed capacity and Sietch count through a temporary configuration gap", async () => {
  const files = fixture();
  const payloads = [];
  const reporterOptions = {
    db: fakeDb(),
    getBattlegroupRunning: () => true,
    fetchImpl: async (url, options) => {
      if (url.endsWith("/heartbeat")) payloads.push(JSON.parse(options.body));
      if (url.endsWith("/claim-status")) return response({ ok: true, claimed: false });
      return response({ ok: true, nextHeartbeatSeconds: 60, listingClaimed: false });
    },
    setTimeoutFn: () => ({ unref() {} })
  };
  const config = {
    repoRoot: files.repoRoot,
    generatedDir: files.generatedDir,
    secretsDir: files.secretsDir
  };

  try {
    const firstReporter = createPublicDirectoryReporter(config, reporterOptions);
    await firstReporter.tick();
    assert.equal(payloads.at(-1).capacity, 120);
    assert.equal(payloads.at(-1).sietches, 2);

    rmSync(join(files.repoRoot, "runtime", "director", "config", "director_config.ini"));
    rmSync(join(files.generatedDir, "sietch-config.json"));

    const restartedReporter = createPublicDirectoryReporter(config, {
      ...reporterOptions,
      db: null,
      getBattlegroupRunning: () => false
    });
    await restartedReporter.tick();

    assert.equal(payloads.at(-1).capacity, 120);
    assert.equal(payloads.at(-1).sietches, 2);
    assert.equal(payloads.at(-1).running, false);
  } finally {
    files.cleanup();
  }
});

test("battlegroup running state distinguishes stopped stacks from partial stacks", async () => {
  assert.equal(await isBattlegroupRunning(() => ["dune-server-survival-1"]), true);
  assert.equal(await isBattlegroupRunning(() => ["dune-postgres", "redblink-dune-docker-console"]), false);
  assert.equal(await isBattlegroupRunning(() => {
    throw new Error("docker unavailable");
  }), false);
});

test("probe reconciliation yields while its Docker command is running", async () => {
  const files = fixture();
  let releaseCommand;
  let commandFinished = false;
  const commandGate = new Promise((resolve) => { releaseCommand = resolve; });
  try {
    const reconciliation = reconcilePublicProbe(files.repoRoot, {
      enabled: true,
      signalingUrl: "https://dunedocker.app/api/v1/probes",
      serverId: "11111111-1111-4111-8111-111111111111",
      secret: "test-secret-placeholder-not-a-real-key"
    }, async () => {
      await commandGate;
      commandFinished = true;
      return "";
    });

    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(commandFinished, false);
    assert.equal(readFileSync(join(files.generatedDir, "public-probe.env"), "utf8").includes("DUNE_PUBLIC_PROBE_ENABLED=true"), true);

    releaseCommand();
    await reconciliation;
    assert.equal(commandFinished, true);
  } finally {
    files.cleanup();
  }
});

test("reporter sends a fresh offline heartbeat when the battlegroup is stopped", async () => {
  const files = fixture();
  let payload;
  try {
    const reporter = createPublicDirectoryReporter({
      repoRoot: files.repoRoot,
      generatedDir: files.generatedDir,
      secretsDir: files.secretsDir
    }, {
      db: {
        async query() {
          throw new Error("stopped battlegroup must not query its database");
        }
      },
      getBattlegroupRunning: () => false,
      fetchImpl: async (_url, options) => {
        payload = JSON.parse(options.body);
        return response({ ok: true, nextHeartbeatSeconds: 60, listingClaimed: false });
      },
      setTimeoutFn: () => ({ unref() {} })
    });

    await reporter.tick();

    assert.equal(payload.running, false);
    assert.equal(payload.ready, false);
    assert.equal(payload.playersOnline, 0);
    assert.equal(reporter.publicState().state, "offline");
  } finally {
    files.cleanup();
  }
});

test("reporter sends only the public directory contract and persists its identity", async () => {
  const files = fixture();
  const requests = [];
  const delays = [];
  try {
    const reporter = createPublicDirectoryReporter({
      repoRoot: files.repoRoot,
      generatedDir: files.generatedDir,
      secretsDir: files.secretsDir
    }, {
      db: fakeDb(),
      getBattlegroupRunning: () => true,
      baseUrl: "https://directory.test/api/v1/servers",
      fetchImpl: async (url, options) => {
        requests.push({ url, options });
        if (url.endsWith("/claim-status")) return response({ ok: true, claimed: true, playerPortalEnabled: false });
        return response({ ok: true, nextHeartbeatSeconds: 75, listingClaimed: true });
      },
      setTimeoutFn: (_fn, delay) => {
        delays.push(delay);
        return { unref() {} };
      },
      now: () => Date.parse("2026-07-16T10:00:00Z")
    });

    await reporter.tick();

    assert.equal(requests.length, 2);
    const heartbeat = requests.find(request => request.url.endsWith("/heartbeat"));
    const claimStatus = requests.find(request => request.url.endsWith("/claim-status"));
    assert.ok(heartbeat);
    assert.ok(claimStatus);
    const payload = JSON.parse(heartbeat.options.body);
    assert.deepEqual(Object.keys(payload).sort(), [
      "capacity",
      "discordInvite",
      "installationKey",
      "name",
      "personalizedPingEnabled",
      "playersOnline",
      "publicMetadata",
      "publicMode",
      "ready",
      "region",
      "running",
      "secret",
      "serverId",
      "sietches",
      "version"
    ]);
    assert.equal(Object.hasOwn(payload, "battlegroupId"), false);
    assert.equal(Object.hasOwn(payload, "serverIp"), false);
    assert.equal(payload.name, "Test Sietch");
    assert.equal(payload.playersOnline, 4);
    assert.equal(payload.personalizedPingEnabled, true);
    assert.equal(payload.discordInvite, "https://discord.gg/Test_Code");
    assert.match(payload.installationKey, /^[0-9a-f]{64}$/);
    assert.doesNotMatch(JSON.stringify(payload), /sh-testbattlegroup-directory/);
    assert.equal(delays.at(-1), 75000);

    const identity = JSON.parse(readFileSync(join(files.secretsDir, "public-directory.json"), "utf8"));
    assert.equal(identity.serverId, payload.serverId);
    assert.equal(identity.secret, payload.secret);
    assert.equal(statSync(join(files.secretsDir, "public-directory.json")).mode & 0o777, 0o600);
    assert.equal(reporter.publicState().remoteListed, true);
    assert.equal(reporter.publicState().listingClaimed, true);
  } finally {
    files.cleanup();
  }
});

test("claim endpoint override does not redirect normal directory heartbeats", async () => {
  const files = fixture();
  const requests = [];
  try {
    const identity = getOrCreateIdentity(join(files.secretsDir, "public-directory.json"));
    const reporter = createPublicDirectoryReporter({
      repoRoot: files.repoRoot,
      generatedDir: files.generatedDir,
      secretsDir: files.secretsDir
    }, {
      db: fakeDb(),
      getBattlegroupRunning: () => true,
      baseUrl: "https://directory.test/api/v1/servers",
      claimBaseUrl: "https://beta-directory.test/api/v1/servers/",
      fetchImpl: async (url, options) => {
        requests.push({ url, options });
        if (url.endsWith("/claim-status")) return response({ ok: true, claimed: false, playerPortalEnabled: false });
        return response({
          ok: true,
          nextHeartbeatSeconds: 60,
          ...(url.endsWith("/heartbeat") ? { listingClaimed: false } : {})
        });
      },
      setTimeoutFn: () => ({ unref() {} })
    });

    await reporter.tick();
    await reporter.verifyClaim("9F06-E912-70F0");

    assert.equal(requests[0].url, "https://directory.test/api/v1/servers/heartbeat");
    assert.equal(
      requests[2].url,
      `https://beta-directory.test/api/v1/servers/${identity.serverId}/verify-claim`
    );
    assert.equal(requests[2].options.headers.authorization, `Bearer ${identity.secret}`);
    assert.deepEqual(JSON.parse(requests[2].options.body), { code: "9F06E91270F0" });
    assert.equal(reporter.publicState().listingClaimed, true);
  } finally {
    files.cleanup();
  }
});

test("reporter uploads only player portal identities requested by the claimed listing", async () => {
  const files = fixture();
  const requests = [];
  const requestedHash = "a".repeat(64);
  let mapOptions;
  const journeyData = { journey_aliases: { journey: "Friendly Journey" } };
  const skillData = [{ id: "Skills.Ability.Test", name: "Friendly Skill" }];
  try {
    const reporter = createPublicDirectoryReporter({
      repoRoot: files.repoRoot,
      generatedDir: files.generatedDir,
      secretsDir: files.secretsDir
    }, {
      db: fakeDb(),
      getBattlegroupRunning: () => true,
      baseUrl: "https://directory.test/api/v1/servers",
      playerPortalJourneyData: journeyData,
      playerPortalSkillData: skillData,
      collectPlayerPortalMarketSnapshot: async () => ({
        available: true,
        listings: [{ sellerActorId: "123" }],
        overview: { available: true, items: [{ templateId: "MelangeSpice", listingCount: 2 }] }
      }),
      collectPlayerPortalMapSnapshot: async (_db, options) => {
        mapOptions = options;
        return ({
        maps: { HaggaBasin: { key: "HaggaBasin" } },
        defaultMap: "HaggaBasin",
        rows: [{ id: "ore-1", type: "ore", name: "TitaniumOre", map: "HaggaBasin", x: 10, y: 20, z: 30 }]
        });
      },
      collectPlayerPortalSnapshots: async (_db, hashes, loadedJourneys, loadedSkills, marketSnapshot) => {
        assert.deepEqual(hashes, [requestedHash]);
        assert.equal(loadedJourneys, journeyData);
        assert.equal(loadedSkills, skillData);
        assert.equal(marketSnapshot.available, true);
        return [{
          accountHash: requestedHash,
          found: true,
          data: {
            overview: { characterName: "Test" },
            exchangeOverview: marketSnapshot.overview
          }
        }];
      },
      fetchImpl: async (url, options) => {
        requests.push({ url, options });
        if (url.endsWith("/heartbeat")) return response({ ok: true, nextHeartbeatSeconds: 60, listingClaimed: true });
        if (url.endsWith("/claim-status")) return response({ ok: true, claimed: true, playerPortalEnabled: true, playerPortalMapEnabled: true, playerPortalMapLayers: ["ore", "poi"], requestedAccountHashes: [requestedHash] });
        if (url.endsWith("/player-portal/market-snapshot")) return response({ ok: true, stored: true });
        if (url.endsWith("/player-portal/map-snapshot")) return response({ ok: true, stored: true });
        return response({ ok: true, stored: 1 });
      },
      setTimeoutFn: () => ({ unref() {} }),
      now: () => Date.parse("2026-07-22T12:00:00Z")
    });

    await reporter.tick();
    assert.ok(requests.some(request => request.url.endsWith(`/claim-status`)));
    const upload = requests.find(request => request.url.endsWith("/player-portal/snapshot"));
    assert.ok(upload);
    const marketUpload = requests.find(request => request.url.endsWith("/player-portal/market-snapshot"));
    assert.ok(marketUpload);
    const mapUpload = requests.find(request => request.url.endsWith("/player-portal/map-snapshot"));
    assert.ok(mapUpload);
    assert.deepEqual(mapOptions, { allowedTypes: ["ore", "poi"] });
    assert.equal(JSON.parse(mapUpload.options.body).map.rows[0].type, "ore");
    assert.equal(JSON.parse(marketUpload.options.body).exchangeOverview.items[0].templateId, "MelangeSpice");
    const body = JSON.parse(upload.options.body);
    assert.equal(body.snapshots.length, 1);
    assert.equal(body.snapshots[0].accountHash, requestedHash);
    assert.equal(Object.hasOwn(body.snapshots[0], "platformId"), false);
    assert.equal(Object.hasOwn(body.snapshots[0].data, "exchangeOverview"), false, "server market data must not be duplicated into every private snapshot");
  } finally {
    files.cleanup();
  }
});

test("reporter does not collect or upload a disabled Player Portal Live Map", async () => {
  const files = fixture();
  const requests = [];
  const requestedHash = "c".repeat(64);
  try {
    const reporter = createPublicDirectoryReporter({
      repoRoot: files.repoRoot,
      generatedDir: files.generatedDir,
      secretsDir: files.secretsDir
    }, {
      db: fakeDb(),
      getBattlegroupRunning: () => true,
      baseUrl: "https://directory.test/api/v1/servers",
      collectPlayerPortalMapSnapshot: async () => assert.fail("disabled map must not be collected"),
      collectPlayerPortalSnapshots: async () => [{ accountHash: requestedHash, found: true, data: {} }],
      collectPlayerPortalMarketSnapshot: async () => null,
      fetchImpl: async (url, options) => {
        requests.push({ url, options });
        if (url.endsWith("/heartbeat")) return response({ ok: true, nextHeartbeatSeconds: 60, listingClaimed: true });
        if (url.endsWith("/claim-status")) return response({ ok: true, claimed: true, playerPortalEnabled: true, playerPortalMapEnabled: false, requestedAccountHashes: [requestedHash] });
        return response({ ok: true, stored: 1 });
      },
      setTimeoutFn: () => ({ unref() {} }),
      now: () => Date.parse("2026-08-29T12:00:00Z")
    });
    await reporter.tick();
    assert.equal(requests.some((request) => request.url.endsWith("/player-portal/map-snapshot")), false);
    assert.equal(requests.some((request) => request.url.endsWith("/player-portal/snapshot")), true);
  } finally {
    files.cleanup();
  }
});

test("reporter never reads or uploads character membership when the Player Portal is disabled", async () => {
  const files = fixture();
  const requests = [];
  const requestedHash = "b".repeat(64);
  try {
    const reporter = createPublicDirectoryReporter({
      repoRoot: files.repoRoot,
      generatedDir: files.generatedDir,
      secretsDir: files.secretsDir
    }, {
      db: fakeDb(),
      getBattlegroupRunning: () => true,
      baseUrl: "https://directory.test/api/v1/servers",
      collectPlayerServerMemberships: async () => {
        assert.fail("a disabled Player Portal must prevent the local character lookup");
      },
      collectPlayerPortalSnapshots: async () => {
        assert.fail("membership discovery must not build a full Player Portal snapshot");
      },
      fetchImpl: async (url, options) => {
        requests.push({ url, options });
        if (url.endsWith("/heartbeat")) return response({ ok: true, nextHeartbeatSeconds: 60, listingClaimed: true });
        if (url.endsWith("/claim-status")) return response({
          ok: true,
          claimed: true,
          playerPortalEnabled: false,
          requestedAccountHashes: [],
          requestedMembershipHashes: [requestedHash]
        });
        return response({ ok: true, stored: 1 });
      },
      setTimeoutFn: () => ({ unref() {} }),
      now: () => Date.parse("2026-08-22T12:00:00Z")
    });

    await reporter.tick();
    const upload = requests.find((request) => request.url.endsWith("/player-membership/snapshot"));
    assert.equal(upload,undefined);
  } finally {
    files.cleanup();
  }
});

test("reporter answers lightweight player membership probes when the Player Portal is enabled", async () => {
  const files = fixture();
  const requests = [];
  const requestedHash = "b".repeat(64);
  try {
    const reporter = createPublicDirectoryReporter({
      repoRoot: files.repoRoot,
      generatedDir: files.generatedDir,
      secretsDir: files.secretsDir
    }, {
      db: fakeDb(),
      getBattlegroupRunning: () => true,
      baseUrl: "https://directory.test/api/v1/servers",
      collectPlayerServerMemberships: async (_db, hashes) => {
        assert.deepEqual(hashes,[requestedHash]);
        return [{ accountHash: requestedHash,found: true,level: 87 }];
      },
      collectPlayerPortalSnapshots: async () => [],
      fetchImpl: async (url,options) => {
        requests.push({ url,options });
        if (url.endsWith("/heartbeat")) return response({ ok: true,nextHeartbeatSeconds: 60,listingClaimed: true });
        if (url.endsWith("/claim-status")) return response({
          ok: true,
          claimed: true,
          playerPortalEnabled: true,
          requestedAccountHashes: [],
          requestedMembershipHashes: [requestedHash]
        });
        return response({ ok: true,stored: 1 });
      },
      setTimeoutFn: () => ({ unref() {} }),
      now: () => Date.parse("2026-08-22T12:00:00Z")
    });

    await reporter.tick();
    const upload = requests.find((request) => request.url.endsWith("/player-membership/snapshot"));
    assert.ok(upload);
    assert.deepEqual(JSON.parse(upload.options.body), {
      observedAt: "2026-08-22T12:00:00.000Z",
      memberships: [{ accountHash: requestedHash, found: true, level: 87 }]
    });
  } finally {
    files.cleanup();
  }
});

test("directory installation keys are stable without exposing battlegroup IDs", () => {
  const files = fixture();
  try {
    const first = readDirectoryInstallationKey(files.repoRoot);
    const second = readDirectoryInstallationKey(files.repoRoot);
    assert.match(first, /^[0-9a-f]{64}$/);
    assert.equal(second, first);
    assert.notEqual(first, "sh-testbattlegroup-directory");

    writeFileSync(join(files.repoRoot, "runtime", "generated", "battlegroup.env"), "BATTLEGROUP_ID=sh-restored-battlegroup\n");
    assert.notEqual(readDirectoryInstallationKey(files.repoRoot), first);
  } finally {
    files.cleanup();
  }
});

test("external restores report the previous opaque installation key only for the adopted battlegroup", () => {
  const files = fixture();
  try {
    const previousKey = readDirectoryInstallationKey(files.repoRoot);
    writeFileSync(join(files.generatedDir, "battlegroup.env"), "BATTLEGROUP_ID=sh-adopted-battlegroup\n");
    writeFileSync(join(files.generatedDir, "battlegroup-restore-point.env"), [
      "PREVIOUS_BATTLEGROUP_ID=sh-testbattlegroup-directory",
      "ADOPTED_BATTLEGROUP_ID=sh-adopted-battlegroup"
    ].join("\n"));

    const currentKey = readDirectoryInstallationKey(files.repoRoot);
    assert.notEqual(currentKey, previousKey);
    assert.equal(readPreviousDirectoryInstallationKey(files.repoRoot, currentKey), previousKey);
    assert.equal(readPreviousDirectoryInstallationKey(files.repoRoot, previousKey), "");

    const payload = buildHeartbeatPayload(
      { serverId: "server-id", secret: "secret" },
      { name: "Test", region: "Europe", running: true, ready: true, playersOnline: 0, capacity: 60,
        version: "2036754", sietches: 1, installationKey: currentKey,
        previousInstallationKey: previousKey, discordInvite: "" }
    );
    assert.equal(payload.installationKey, currentKey);
    assert.equal(payload.previousInstallationKey, previousKey);
    assert.doesNotMatch(JSON.stringify(payload), /sh-(test|adopted)-battlegroup/);
  } finally {
    files.cleanup();
  }
});

test("Discord invite normalization accepts only official invite URLs", () => {
  assert.equal(normalizeDiscordInvite("https://discord.gg/Test_Code"), "https://discord.gg/Test_Code");
  assert.equal(normalizeDiscordInvite("https://discord.com/invite/Test-Code/"), "https://discord.gg/Test-Code");
  assert.equal(normalizeDiscordInvite("https://www.discord.com/invite/TestCode"), "https://discord.gg/TestCode");
  assert.equal(normalizeDiscordInvite(""), "");
  assert.equal(normalizeDiscordInvite("https://example.com/invite/TestCode"), null);
  assert.equal(normalizeDiscordInvite("https://discord.gg/TestCode?tracking=1"), null);
  assert.equal(normalizeDiscordInvite("javascript:alert(1)"), null);
});

test("directory receipt configures the authenticated outbound WebRTC probe", async () => {
  const files = fixture();
  const reconciles = [];
  try {
    const reporter = createPublicDirectoryReporter({
      repoRoot: files.repoRoot,
      generatedDir: files.generatedDir,
      secretsDir: files.secretsDir
    }, {
      db: fakeDb(),
      getBattlegroupRunning: () => true,
      fetchImpl: async () => response({
        ok: true,
        nextHeartbeatSeconds: 60,
        probe: {
          mode: "webrtc",
          signalingUrl: "https://dunedocker.app/api/v1/probes"
        }
      }),
      reconcileProbe: async (probe) => reconciles.push(probe),
      setTimeoutFn: () => ({ unref() {} })
    });

    await reporter.tick();

    assert.equal(reconciles.length, 1);
    assert.equal(reconciles[0].enabled, true);
    assert.equal(reconciles[0].signalingUrl, "https://dunedocker.app/api/v1/probes");
    assert.match(reconciles[0].serverId, /^[0-9a-f-]{36}$/i);
    assert.match(reconciles[0].secret, /^[A-Za-z0-9_-]{32,128}$/);
    assert.equal(reporter.publicState().probeEndpoint, "https://dunedocker.app/api/v1/probes");
    assert.equal(reporter.publicState().probeState, "started");
    assert.equal(reporter.publicState().probeError, null);
  } finally {
    files.cleanup();
  }
});

test("invalid personalized ping signaling URLs are ignored", async () => {
  const files = fixture();
  const reconciles = [];
  try {
    const reporter = createPublicDirectoryReporter({
      repoRoot: files.repoRoot,
      generatedDir: files.generatedDir,
      secretsDir: files.secretsDir
    }, {
      db: fakeDb(),
      getBattlegroupRunning: () => true,
      fetchImpl: async () => response({
        ok: true,
        probe: {
          mode: "webrtc",
          signalingUrl: "https://attacker.example/api/v1/probes"
        }
      }),
      reconcileProbe: async (probe) => reconciles.push(probe),
      setTimeoutFn: () => ({ unref() {} })
    });

    await reporter.tick();

    assert.deepEqual(reconciles, []);
    assert.equal(reporter.publicState().probeEndpoint, null);
    assert.equal(reporter.publicState().probeState, "unavailable");
  } finally {
    files.cleanup();
  }
});

test("unsupported personalized ping modes are ignored", async () => {
  const files = fixture();
  const reconciles = [];
  try {
    const reporter = createPublicDirectoryReporter({
      repoRoot: files.repoRoot,
      generatedDir: files.generatedDir,
      secretsDir: files.secretsDir
    }, {
      db: fakeDb(),
      getBattlegroupRunning: () => true,
      fetchImpl: async () => response({
        ok: true,
        probe: {
          mode: "https",
          signalingUrl: "https://dunedocker.app/api/v1/probes"
        }
      }),
      reconcileProbe: async (probe) => reconciles.push(probe),
      setTimeoutFn: () => ({ unref() {} })
    });

    await reporter.tick();

    assert.deepEqual(reconciles, []);
    assert.equal(reporter.publicState().probeEndpoint, null);
  } finally {
    files.cleanup();
  }
});

test("an immediate UI-triggered heartbeat replaces the scheduled timer", async () => {
  const files = fixture();
  const cleared = [];
  let timerId = 0;
  try {
    const reporter = createPublicDirectoryReporter({
      repoRoot: files.repoRoot,
      generatedDir: files.generatedDir,
      secretsDir: files.secretsDir
    }, {
      db: fakeDb(),
      getBattlegroupRunning: () => true,
      fetchImpl: async () => response({ ok: true, nextHeartbeatSeconds: 60 }),
      setTimeoutFn: () => ({ id: ++timerId, unref() {} }),
      clearTimeoutFn: (timer) => cleared.push(timer.id),
      random: () => 0
    });
    reporter.start();
    await reporter.tick();
    assert.deepEqual(cleared, [1]);
  } finally {
    files.cleanup();
  }
});

test("reporter removes a previous listing and reports anonymous presence after switching to local mode", async () => {
  const files = fixture();
  const identityPath = join(files.secretsDir, "public-directory.json");
  const statusPath = join(files.generatedDir, "public-directory-status.json");
  const identity = getOrCreateIdentity(identityPath);
  writeFileSync(statusPath, JSON.stringify({ remoteListed: true, serverId: identity.serverId }));
  writeFileSync(join(files.repoRoot, ".env"), "SERVER_IP_MODE=local\nSERVER_TITLE=Private\nSERVER_REGION=Europe\n");
  const requests = [];
  try {
    const reporter = createPublicDirectoryReporter({
      repoRoot: files.repoRoot,
      generatedDir: files.generatedDir,
      secretsDir: files.secretsDir
    }, {
      db: fakeDb(),
      baseUrl: "https://directory.test/api/v1/servers",
      getBattlegroupRunning: () => false,
      fetchImpl: async (url, options) => {
        requests.push({ url, options });
        return response({ ok: true });
      },
      setTimeoutFn: () => ({ unref() {} })
    });

    await reporter.tick();

    assert.equal(requests.length, 2);
    assert.equal(requests[0].options.method, "DELETE");
    assert.equal(requests[0].url, `https://directory.test/api/v1/servers/${identity.serverId}`);
    assert.equal(requests[0].options.headers.authorization, `Bearer ${identity.secret}`);
    assert.equal(requests[1].options.method, "POST");
    assert.equal(requests[1].url, "https://directory.test/api/v1/server-presence/heartbeat");
    assert.deepEqual(JSON.parse(requests[1].options.body), {
      serverId: identity.serverId,
      secret: identity.secret,
      installationKey: readDirectoryInstallationKey(files.repoRoot),
      visibility: "local",
      running: false,
      version: "2036754"
    });
    assert.equal(reporter.publicState().state, "anonymous-reporting");
    assert.equal(reporter.publicState().remoteListed, false);
  } finally {
    files.cleanup();
  }
});

test("reporter records errors and backs off without exposing its secret", async () => {
  const files = fixture();
  const delays = [];
  try {
    const reporter = createPublicDirectoryReporter({
      repoRoot: files.repoRoot,
      generatedDir: files.generatedDir,
      secretsDir: files.secretsDir
    }, {
      db: fakeDb(),
      getBattlegroupRunning: () => true,
      fetchImpl: async () => response({ error: "temporary failure" }, 503),
      setTimeoutFn: (_fn, delay) => {
        delays.push(delay);
        return { unref() {} };
      }
    });

    await reporter.tick();

    const state = reporter.publicState();
    assert.equal(state.state, "error");
    assert.match(state.error, /HTTP 503/);
    assert.equal(Object.hasOwn(state, "secret"), false);
    assert.equal(delays.at(-1), 30000);
    assert.equal(Object.hasOwn(JSON.parse(readFileSync(
      join(files.generatedDir, "public-directory-status.json"),
      "utf8"
    )), "secret"), false);
  } finally {
    files.cleanup();
  }
});

test("corrupt identity files are replaced with private valid credentials", () => {
  const files = fixture();
  const path = join(files.secretsDir, "public-directory.json");
  try {
    writeFileSync(path, "{\"serverId\":\"bad\"}\n");
    chmodSync(path, 0o644);
    const identity = getOrCreateIdentity(path);
    assert.match(identity.serverId, /^[0-9a-f-]{36}$/i);
    assert.match(identity.secret, /^[A-Za-z0-9_-]{32,128}$/);
    assert.equal(statSync(path).mode & 0o777, 0o600);
  } finally {
    files.cleanup();
  }
});

test("persisted status is field-whitelisted before API exposure", () => {
  const files = fixture();
  try {
    writeFileSync(join(files.generatedDir, "public-directory-status.json"), JSON.stringify({
      state: "online",
      serverId: "11111111-1111-4111-8111-111111111111",
      secret: "must-not-leak",
      unexpected: { nested: true }
    }));
    const reporter = createPublicDirectoryReporter({
      repoRoot: files.repoRoot,
      generatedDir: files.generatedDir,
      secretsDir: files.secretsDir
    }, {
      db: fakeDb(),
      setTimeoutFn: () => ({ unref() {} })
    });
    const state = reporter.publicState();
    assert.equal(state.state, "online");
    assert.equal(Object.hasOwn(state, "secret"), false);
    assert.equal(Object.hasOwn(state, "unexpected"), false);
  } finally {
    files.cleanup();
  }
});
