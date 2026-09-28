import test from "node:test";
import assert from "node:assert/strict";
import { baseInventory } from "../src/duneDb.js";

// Every table the query touches, including the LEFT JOINed ones -- a missing
// relation raises at parse time regardless of join type. permission_actor is
// the reachable gap: listBases probes buildings/building_instances/
// actor_fgl_entities/actors, so a schema lacking only permission_actor lists
// bases fine and fails on this tab alone.
const REQUIRED_TABLES = [
  "dune.buildings", "dune.building_instances", "dune.actor_fgl_entities",
  "dune.placeables", "dune.inventories", "dune.permission_actor", "dune.items"
];
const BASE_ID = 1006;

// Template ids deliberately absent from runtime/data/admin-items.json, so the
// assertions below test this module's fallback rather than tracking whatever
// the shipped catalog happens to call a real item this week.
function row(overrides = {}) {
  return {
    placeable_id: "40001",
    inventory_id: "500",
    group_key: "storage",
    type_name: "Storage Container",
    container_name: "",
    max_item_count: 45,
    template_id: "TestOre",
    stack_size: 10,
    ...overrides
  };
}

// Column-probed the same way baseContainerSlots's own itemColumns fixture
// works (db.test.js): defaults to a schema WITHOUT max_item_volume/
// volume_override, since the fake db's information_schema.columns query
// falls through to the generic `{ rows }` branch below otherwise, which
// would carry no column_name field and degrade to false regardless -- this
// makes that default explicit rather than accidental.
function createDb({ rows = [], missingTable = "", inventoryColumns = [], itemColumns = [] } = {}) {
  const calls = [];
  const db = {
    calls,
    query: async (text, values = []) => {
      calls.push({ text, values });
      if (text.includes("to_regclass")) {
        const table = String(values[0] || "");
        return { rows: [{ exists: REQUIRED_TABLES.includes(table) && table !== missingTable }] };
      }
      if (text.includes("information_schema.columns")) {
        const columns = values[1] === "inventories" ? inventoryColumns : itemColumns;
        return { rows: columns.map((column_name) => ({ column_name })) };
      }
      return { rows };
    }
  };
  return db;
}

function mainQuery(db) {
  return db.calls.find((call) => call.text.includes("requested_claims"));
}

test("baseInventory rolls items up by template and by container", async () => {
  const db = createDb({
    rows: [
      row({ placeable_id: "40001", inventory_id: "500", template_id: "TestOre", stack_size: 10 }),
      row({ placeable_id: "40001", inventory_id: "500", template_id: "TestBar", stack_size: 3 }),
      row({ placeable_id: "40002", inventory_id: "501", container_name: "Ore Stash", max_item_count: 20, template_id: "TestOre", stack_size: 25 }),
      row({
        placeable_id: "40003", inventory_id: "502", group_key: "refining",
        type_name: "Small Ore Refinery", max_item_count: 5, template_id: "TestOre", stack_size: 7
      })
    ]
  });

  const result = await baseInventory(db, BASE_ID);

  assert.equal(result.baseId, BASE_ID);
  // Sorted by quantity descending: 42 of TestOre across three containers.
  assert.deepEqual(result.items.map((item) => [item.templateId, item.quantity, item.containerCount]), [
    ["TestOre", 42, 3],
    ["TestBar", 3, 1]
  ]);
  assert.deepEqual(result.items[0].containers.map((holder) => [holder.placeableId, holder.quantity]), [
    ["40002", 25],
    ["40001", 10],
    ["40003", 7]
  ]);
  // No catalog entry, so name falls back to the raw template id.
  assert.equal(result.items[0].name, "TestOre");

  assert.deepEqual(result.containers.map((container) => [container.placeableId, container.usedSlots, container.maxSlots]), [
    ["40002", 1, 20],
    ["40001", 2, 45],
    ["40003", 1, 5]
  ]);
  assert.deepEqual(result.totals, { items: 45, distinct: 2, containers: 3, usedSlots: 4, maxSlots: 70, currentVolume: 0, maxVolume: 0, volumeComplete: false });
  assert.deepEqual(result.groups, [
    { key: "storage", name: "Storage", containerCount: 2, itemCount: 38 },
    { key: "refining", name: "Refining", containerCount: 1, itemCount: 7 },
    { key: "crafting", name: "Crafting", containerCount: 0, itemCount: 0 },
    { key: "other", name: "Other", containerCount: 0, itemCount: 0 }
  ]);
});

test("baseInventory keeps an empty container instead of dropping it", async () => {
  // The left join against dune.items emits one all-null item row for a
  // container holding nothing.
  const db = createDb({
    rows: [row({ placeable_id: "40010", inventory_id: "510", template_id: null, stack_size: null, max_item_count: 5, group_key: "other", type_name: "Repair Station" })]
  });

  const result = await baseInventory(db, BASE_ID);

  assert.deepEqual(result.containers, [{
    placeableId: "40010",
    name: "",
    typeName: "Repair Station",
    group: "other",
    usedSlots: 0,
    maxSlots: 5,
    currentVolume: 0,
    maxVolume: 0,
    volumeComplete: false,
    itemCount: 0,
    items: []
  }]);
  assert.deepEqual(result.items, []);
  assert.equal(result.totals.containers, 1);
  assert.equal(result.totals.distinct, 0);
});

test("baseInventory counts a container's capacity once per inventory, not per item row", async () => {
  // Every item row repeats its inventory's max_item_count; summing blindly
  // would report 135 slots for one 45-slot container.
  const db = createDb({
    rows: [
      row({ template_id: "TestOre", stack_size: 1 }),
      row({ template_id: "TestBar", stack_size: 1 }),
      row({ template_id: "TestGem", stack_size: 1 })
    ]
  });

  const result = await baseInventory(db, BASE_ID);

  assert.equal(result.containers.length, 1);
  assert.equal(result.containers[0].maxSlots, 45);
  assert.equal(result.containers[0].usedSlots, 3);
});

test("baseInventory merges repeated stacks of one template within a container", async () => {
  const db = createDb({
    rows: [
      row({ template_id: "TestOre", stack_size: 100 }),
      row({ template_id: "TestOre", stack_size: 40 })
    ]
  });

  const result = await baseInventory(db, BASE_ID);

  assert.deepEqual(result.containers[0].items, [{ templateId: "TestOre", name: "TestOre", quantity: 140 }]);
  assert.equal(result.containers[0].usedSlots, 2, "two stacks occupy two slots even when merged for display");
  assert.equal(result.items[0].containerCount, 1);
});

test("baseInventory leaves the container name empty when the game holds only its default", async () => {
  // dune.permission_actor.actor_name is '##' || building_type until a player
  // renames the placeable; the SQL strips that, so "" reaches the frontend
  // and it falls back to the type name.
  const db = createDb({ rows: [row({ container_name: "" })] });

  const result = await baseInventory(db, BASE_ID);

  assert.equal(result.containers[0].name, "");
  assert.equal(result.containers[0].typeName, "Storage Container");
});

test("baseInventory only ever asks for allowlisted building types", async () => {
  const db = createDb({ rows: [] });
  await baseInventory(db, BASE_ID);

  const [, groups, buildingTypes] = mainQuery(db).values;
  assert.ok(buildingTypes.includes("storagecontainer_placeable"));
  assert.ok(buildingTypes.includes("spicesilo_placeable"));
  assert.ok(buildingTypes.includes("smallorerefinery_placeable"));
  assert.ok(buildingTypes.includes("recycler_placeable"));
  assert.ok(buildingTypes.includes("repairstation_placeable"));
  assert.ok(buildingTypes.includes("totem_small_placeable"));
  assert.ok(buildingTypes.includes("totem_placeable"));
  // The Power tab owns generator fuel and windtrap filters, the Water tab
  // cisterns and stored water; an unrecognised placeable must not
  // acquire a group by accident either.
  assert.ok(!buildingTypes.includes("generator_placeable"));
  assert.ok(!buildingTypes.includes("windtrap_placeable"));
  assert.ok(!buildingTypes.includes("watercistern_placeable"));
  assert.equal(groups.length, buildingTypes.length);
  assert.deepEqual([...new Set(groups)], ["storage", "refining", "crafting", "other"]);
  // Refineries and fabricators are separate groups, not one "production" bucket.
  assert.equal(groups[buildingTypes.indexOf("smallorerefinery_placeable")], "refining");
  assert.equal(groups[buildingTypes.indexOf("survivalfabricator_placeable")], "crafting");
  // The base's own claim structure lands in Other alongside the recycler and
  // repair station, not a bucket of its own.
  assert.equal(groups[buildingTypes.indexOf("totem_small_placeable")], "other");
  assert.equal(groups[buildingTypes.indexOf("totem_placeable")], "other");
});

test("baseInventory drops the uncapped second inventory refineries carry", async () => {
  const db = createDb({ rows: [] });
  await baseInventory(db, BASE_ID);

  assert.match(mainQuery(db).text, /inv\.max_item_count >= 0/);
});

// A capability response, not a throw: a schema that cannot back the tab is a
// settled answer the UI states plainly, so it must not reach the caller as an
// error indistinguishable from a transient failure.
test("baseInventory reports unsupported when a required table is missing", async () => {
  for (const table of REQUIRED_TABLES) {
    const db = createDb({ missingTable: table });
    const result = await baseInventory(db, BASE_ID);
    assert.equal(result.supported, false);
    assert.match(result.reason, new RegExp(table.replace(".", "\\.")));
    // The point of probing is to never issue the query that would have raised
    // "relation ... does not exist" -- answering after the fact would defeat it.
    assert.equal(mainQuery(db), undefined, `${table} missing: the query must not run`);
    // Still shaped like a real response, so nothing downstream has to guard
    // every field before reading it.
    assert.deepEqual(result.containers, []);
    assert.deepEqual(result.items, []);
    assert.deepEqual(result.totals, { items: 0, distinct: 0, containers: 0, usedSlots: 0, maxSlots: 0, currentVolume: 0, maxVolume: 0, volumeComplete: false });
  }
});

test("baseInventory rejects an invalid base id", async () => {
  const db = createDb({ rows: [] });
  await assert.rejects(() => baseInventory(db, 0));
  await assert.rejects(() => baseInventory(db, "not-a-base"));
});

// Game-created rows normally leave volume_override NULL, meaning the game uses
// the template's own catalog volume. The console must do the same rather than
// silently treating established inventory as volume-free.
//
// CORRECTED 2026-08-19 (real live in-game bug, see
// docs/incidents/INC-2026-08-19-VOLUME-OVERRIDE-DOUBLE-MULTIPLIED.md):
// volume_override is a PER-UNIT value, not the stack's total -- the total
// contribution of a row is volume_override * stack_size.
test("baseInventory reports current and max volume per container, summed once per inventory", async () => {
  const db = createDb({
    inventoryColumns: ["id", "actor_id", "max_item_count", "max_item_volume"],
    itemColumns: ["id", "inventory_id", "template_id", "stack_size", "volume_override"],
    rows: [
      row({ placeable_id: "40001", inventory_id: "500", max_item_count: 45, max_item_volume: 500, template_id: "TestOre", stack_size: 10, volume_override: 4 }),
      row({ placeable_id: "40001", inventory_id: "500", max_item_count: 45, max_item_volume: 500, template_id: "TestBar", stack_size: 3, volume_override: 5 })
    ]
  });

  const result = await baseInventory(db, BASE_ID);

  assert.equal(result.containers[0].maxVolume, 500, "max volume is read once per inventory, not summed per item row");
  assert.equal(result.containers[0].currentVolume, 55, "current volume sums volume_override (a per-unit value) * stack_size across every row");
  assert.equal(result.totals.currentVolume, 55);
  assert.equal(result.totals.maxVolume, 500);
});

test("baseInventory falls back to catalog volume for normal game-created NULL overrides", async () => {
  const db = createDb({
    inventoryColumns: ["id", "actor_id", "max_item_count", "max_item_volume"],
    itemColumns: ["id", "inventory_id", "template_id", "stack_size", "volume_override"],
    rows: [row({ max_item_volume: 500, template_id: "AzuriteOre", stack_size: 10, volume_override: null })]
  });

  const result = await baseInventory(db, BASE_ID);

  assert.equal(result.containers[0].currentVolume, 2);
  assert.equal(result.containers[0].volumeComplete, true);
  assert.equal(result.totals.volumeComplete, true);
});

test("baseInventory degrades volume to 0/0 on a schema without max_item_volume/volume_override, rather than failing", async () => {
  const db = createDb({
    inventoryColumns: ["id", "actor_id", "max_item_count"],
    itemColumns: ["id", "inventory_id", "template_id", "stack_size"],
    rows: [row({ template_id: "TestOre", stack_size: 10 })]
  });

  const result = await baseInventory(db, BASE_ID);

  assert.equal(result.containers[0].currentVolume, 0);
  assert.equal(result.containers[0].maxVolume, 0);
  const query = mainQuery(db);
  assert.match(query.text, /0::real as max_item_volume/);
  assert.match(query.text, /0::real as volume_override/);
});
