-- migrate:up

-- What a reader of the meters' own stores may rely on, as an interface: a row
-- is keyed on (meter_serial, register_key, meter_time) and never changes once
-- it is shown, so a reader may keep the key as a pointer. The evidence of
-- each copy (slot, address, batch) stays in health.stored_entries.
-- contract: central/test/meter_stores.sql, central/test/grants.sql
CREATE SCHEMA meter_stores;

GRANT USAGE ON SCHEMA meter_stores TO monitor;

-- Every quantity of every history entry copied, as first stored. meter_time
-- is the meter's own stamp, local, no zone: an entry closed at any time, not
-- only at a month's start. conflicts counts the copies under the same key
-- that said otherwise (meter_stores.history_conflicts): the value stands as
-- first stored, which is not a verdict that it is the right one.
CREATE VIEW meter_stores.history AS
  SELECT s.meter_serial, s.register_key, s.meter_time, s.value, q.unit, s.profile,
         s.profile_version, s.product_code, s.copied_at, s.collector_id, b.received_at,
         coalesce(k.conflicts, 0) AS conflicts
  FROM store.stored_entries s
  JOIN store.profile_stored q
    ON (q.profile, q.version, q.store, q.register_key)
       = (s.profile, s.profile_version, s.store, s.register_key)
  JOIN store.batches b ON b.batch_id = s.batch_id
  LEFT JOIN (
    SELECT meter_serial, register_key, meter_time, count(*) AS conflicts
    FROM store.stored_entry_conflicts
    WHERE store = 'history'
    GROUP BY meter_serial, register_key, meter_time
  ) k ON (k.meter_serial, k.register_key, k.meter_time)
         = (s.meter_serial, s.register_key, s.meter_time)
  WHERE s.store = 'history';

GRANT SELECT ON TABLE meter_stores.history TO monitor;

-- Each copy of a history entry that said otherwise than the one stored under
-- its key, once per batch that brought it.
CREATE VIEW meter_stores.history_conflicts AS
  SELECT c.meter_serial, c.register_key, c.meter_time, c.value, q.unit, c.profile,
         c.profile_version, c.product_code, c.copied_at, c.collector_id, c.received_at
  FROM store.stored_entry_conflicts c
  JOIN store.profile_stored q
    ON (q.profile, q.version, q.store, q.register_key)
       = (c.profile, c.profile_version, c.store, c.register_key)
  WHERE c.store = 'history';

GRANT SELECT ON TABLE meter_stores.history_conflicts TO monitor;

-- migrate:down
-- Forward only. Undo with a new migration.
