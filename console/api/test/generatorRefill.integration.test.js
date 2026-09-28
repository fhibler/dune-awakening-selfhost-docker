import test from "node:test";
import assert from "node:assert/strict";
import { refillBaseGenerators } from "../src/duneDb.js";
import { pgTransactionalDb, withIsolatedDatabase } from "../test-support/pgIntegrationDb.js";

test("real PostgreSQL serializes concurrent refills of an empty generator inventory", async (t) => {
  await withIsolatedDatabase(t, {
    namePrefix: "dune_refill",
    unavailableLabel: "the refill concurrency test",
    createFailLabel: "the refill concurrency test"
  }, async (pool) => {
    await pool.query(`
      create schema dune;
      create table dune.buildings (id bigint primary key);
      create table dune.building_instances (building_id bigint not null, owner_entity_id bigint not null);
      create table dune.actor_fgl_entities (entity_id bigint not null, actor_id bigint not null);
      create table dune.placeables (
        id bigint primary key,
        owner_entity_id bigint not null,
        building_type text not null,
        is_hologram boolean not null default false
      );
      create table dune.inventories (
        id bigint primary key,
        actor_id bigint not null,
        max_item_count integer not null,
        max_item_volume integer not null default 0
      );
      create table dune.items (
        id bigint generated always as identity primary key,
        inventory_id bigint not null references dune.inventories(id),
        template_id text not null,
        stack_size integer not null,
        quality_level integer not null,
        position_index integer not null,
        stats jsonb not null
      );
      insert into dune.buildings values (482);
      insert into dune.building_instances values (482, 100);
      insert into dune.actor_fgl_entities values (100, 200);
      insert into dune.placeables values (5001, 100, 'generator_placeable');
      insert into dune.inventories (id, actor_id, max_item_count) values (701, 5001, 10);
    `);

    const db = pgTransactionalDb(pool);
    const [first, second] = await Promise.all([
      refillBaseGenerators(db, "", 482),
      refillBaseGenerators(db, "", 482)
    ]);
    const stored = await pool.query(`
      select count(*)::int as rows, coalesce(sum(stack_size), 0)::int as units
      from dune.items
      where inventory_id = 701 and lower(template_id) = 'oil'`);

    assert.deepEqual(stored.rows[0], { rows: 1, units: 499 });
    assert.equal(first.totalAdded + second.totalAdded, 499);
  });
});

test("real PostgreSQL refills windtrap filters in the tier each windtrap already uses", async (t) => {
  await withIsolatedDatabase(t, {
    namePrefix: "dune_refill_windtrap",
    unavailableLabel: "the windtrap refill test",
    createFailLabel: "the windtrap refill test"
  }, async (pool) => {
    await pool.query(`
      create schema dune;
      create table dune.buildings (id bigint primary key);
      create table dune.building_instances (building_id bigint not null, owner_entity_id bigint not null);
      create table dune.fgl_entities (entity_id bigint primary key, components jsonb not null);
      create table dune.actor_fgl_entities (entity_id bigint not null, actor_id bigint not null);
      create table dune.placeables (
        id bigint primary key,
        owner_entity_id bigint not null,
        building_type text not null,
        is_hologram boolean not null default false
      );
      create table dune.inventories (
        id bigint primary key,
        actor_id bigint not null,
        max_item_count integer not null,
        max_item_volume integer not null default 0
      );
      create table dune.items (
        id bigint generated always as identity primary key,
        inventory_id bigint not null references dune.inventories(id),
        template_id text not null,
        stack_size integer not null,
        quality_level integer not null,
        position_index integer not null,
        stats jsonb not null
      );
      insert into dune.buildings values (483);
      insert into dune.building_instances values (483, 100);
      insert into dune.actor_fgl_entities values (100, 200);
      -- Building types as the game writes them: mixed case.
      -- 5006 is an unbuilt hologram: it has an inventory but must be skipped.
      insert into dune.placeables values
        (5003, 100, 'Windtrap_Placeable', false),
        (5004, 100, 'Windtrap_Placeable', false),
        (5005, 100, 'LargeWindtrap_Placeable', false),
        (5006, 100, 'Windtrap_Placeable', true);
      insert into dune.inventories values (703, 5003, 5, 25), (704, 5004, 5, 25), (705, 5005, 5, 25), (706, 5006, 5, 25);
      insert into dune.items (inventory_id, template_id, stack_size, quality_level, position_index, stats)
        values (703, 'WindTrapFilter1', 2, 0, 0, '{}');
      insert into dune.fgl_entities values
        (904, '{"FFuelPoweredPlaceableComponent": [0, {"m_FuelBurningId": {"Name": "WindTrapFilter1"}, "m_FuelBurningDuration": 10800.0}]}'),
        (905, '{"FFuelPoweredPlaceableComponent": [0, {"m_FuelBurningId": {"Name": "None"}, "m_FuelBurningDuration": 3600.0}]}');
      insert into dune.actor_fgl_entities values (904, 5004), (905, 5005);
    `);

    const result = await refillBaseGenerators(pgTransactionalDb(pool), "", 483);
    const stored = await pool.query(`
      select inventory_id::int as inventory, template_id, stack_size
      from dune.items order by inventory_id, position_index`);

    // Held tier is topped up; an empty windtrap follows its burning tier; an
    // idle, empty Large Windtrap gets the default. Never more than 5 filters,
    // and nothing lands in the hologram's inventory (706).
    assert.deepEqual(stored.rows, [
      { inventory: 703, template_id: "WindTrapFilter1", stack_size: 5 },
      { inventory: 704, template_id: "WindTrapFilter1", stack_size: 5 },
      { inventory: 705, template_id: "WindTrapFilter4", stack_size: 5 }
    ]);
    assert.equal(result.totalAdded, 13);
    assert.equal(result.devices.length, 3);
    const again = await refillBaseGenerators(pgTransactionalDb(pool), "", 483);
    assert.equal(again.totalAdded, 0);
  });
});
