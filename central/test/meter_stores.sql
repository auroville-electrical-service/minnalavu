-- meter_stores.history and meter_stores.history_conflicts: every quantity of
-- every history entry, under a key that never changes, with its conflicts.

\ir lib/assert.sql
\set basic `cat ../contract/fixtures/batch.v1.basic.json`

BEGIN;

SELECT admin.create_collector('sqltest_ms');

CREATE FUNCTION pg_temp.renamed(batch jsonb, id text) RETURNS jsonb
LANGUAGE sql AS $$
  SELECT jsonb_set(batch, '{batch_id}', to_jsonb(id))
$$;

-- The basic batch under this id with its entry at index i given this value.
CREATE FUNCTION pg_temp.revalued(basic jsonb, id text, i int, value text) RETURNS jsonb
LANGUAGE sql AS $$
  SELECT pg_temp.changed(pg_temp.renamed(basic, id),
    jsonb_build_object('path', jsonb_build_array('stored_entries', i, 'value'), 'value', value))
$$;

CREATE FUNCTION pg_temp.history_rows() RETURNS text
LANGUAGE sql AS $$
  SELECT string_agg(format('%s %s %s %s %s %s %s %s %s %s %s', meter_serial, register_key,
                           meter_time, value, unit, profile, profile_version, product_code,
                           copied_at, collector_id, conflicts), '; '
                    ORDER BY meter_serial, register_key, meter_time)
  FROM meter_stores.history
$$;

SELECT pg_temp.ingest_as('collector_sqltest_ms', :'basic');

SELECT pg_temp.is(
  pg_temp.history_rows(),
  'SIM-445-0001 active_energy_import 2026-11-01 00:00:00 1234.5 kWh elite_440 2 ELITE440-445 '
  || '2026-11-01 00:00:04+00 sqltest_ms 0',
  'a history entry is shown with its unit, its decode and its copy, and no snapshot or '
  || 'load-survey entry is');

SELECT pg_temp.is(
  (SELECT received_at = now() FROM meter_stores.history),
  true,
  'and with when its batch first arrived');

SELECT pg_temp.ingest_as('collector_sqltest_ms',
  pg_temp.renamed(:'basic', 'a1a1a1a1-a1a1-4a1a-8a1a-a1a1a1a1a1a1'));

SELECT pg_temp.is(
  (SELECT conflicts FROM meter_stores.history),
  0::bigint,
  'a recopy that says the same is no conflict');

SELECT pg_temp.ingest_as('collector_sqltest_ms',
  pg_temp.revalued(:'basic', 'a2a2a2a2-a2a2-4a2a-8a2a-a2a2a2a2a2a2', 0, '1234.6'));
SELECT pg_temp.ingest_as('collector_sqltest_ms',
  pg_temp.revalued(:'basic', 'a3a3a3a3-a3a3-4a3a-8a3a-a3a3a3a3a3a3', 0, '1234.7'));
SELECT pg_temp.ingest_as('collector_sqltest_ms',
  pg_temp.revalued(:'basic', 'a4a4a4a4-a4a4-4a4a-8a4a-a4a4a4a4a4a4', 2, '1.5'));

SELECT pg_temp.is(
  (SELECT format('%s %s', value, conflicts) FROM meter_stores.history),
  '1234.5 2',
  'each recopy that says otherwise is counted, and the value stands as first stored');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s %s %s %s %s %s %s %s %s', meter_serial, register_key,
                            meter_time, value, unit, profile, profile_version, product_code,
                            copied_at, collector_id), '; ' ORDER BY value)
   FROM meter_stores.history_conflicts),
  'SIM-445-0001 active_energy_import 2026-11-01 00:00:00 1234.6 kWh elite_440 2 ELITE440-445 '
  || '2026-11-01 00:00:04+00 sqltest_ms; '
  || 'SIM-445-0001 active_energy_import 2026-11-01 00:00:00 1234.7 kWh elite_440 2 ELITE440-445 '
  || '2026-11-01 00:00:04+00 sqltest_ms',
  'each conflicting history copy is shown with its unit, and no snapshot conflict is');

SELECT pg_temp.is(
  (SELECT bool_and(received_at = now()) FROM meter_stores.history_conflicts),
  true,
  'each with when it arrived');

-- Every history quantity of each profile, one entry each.
SELECT admin.create_collector('sqltest_ms_all');
INSERT INTO store.batches VALUES ('b0b0b0b0-b0b0-4b0b-8b0b-b0b0b0b0b0b0', 'sqltest_ms_all',
  now(), 'ntp', NULL, 0, 0);
INSERT INTO store.stored_entries
  (meter_serial, store, register_key, meter_time, value, interval_s, profile, profile_version,
   product_code, slot, copied_at, endpoint_host, endpoint_port, unit_id, collector_id, batch_id)
SELECT 'ALL-' || q.profile, q.store, q.register_key, '2026-10-01T00:00:00', 1,
       CASE WHEN q.store = 'load_survey' THEN 1800 END, q.profile,
       q.version, 'any', 1, now(), '10.0.0.70', 502, 1, 'sqltest_ms_all',
       'b0b0b0b0-b0b0-4b0b-8b0b-b0b0b0b0b0b0'
FROM store.profile_stored q
WHERE q.version = 2;

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s', register_key, unit), ', ' ORDER BY register_key)
   FROM meter_stores.history WHERE meter_serial = 'ALL-elite_440'),
  'active_energy_export kWh, active_energy_import kWh, apparent_energy_export kVAh, '
  || 'apparent_energy_import kVAh, reactive_energy_export kvarh, '
  || 'reactive_energy_export_while_active_export kvarh, '
  || 'reactive_energy_export_while_active_import kvarh, reactive_energy_import kvarh, '
  || 'reactive_energy_import_while_active_export kvarh, '
  || 'reactive_energy_import_while_active_import kvarh',
  'every history quantity of elite_440 is shown, once');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s', register_key, unit), ', ' ORDER BY register_key)
   FROM meter_stores.history WHERE meter_serial = 'ALL-elite_500'),
  'active_energy_export kWh, active_energy_export_l1 kWh, active_energy_export_l2 kWh, '
  || 'active_energy_export_l3 kWh, active_energy_forwarded kWh, active_energy_import kWh, '
  || 'active_energy_import_l1 kWh, active_energy_import_l2 kWh, active_energy_import_l3 kWh, '
  || 'apparent_energy_export kVAh, apparent_energy_forwarded kVAh, apparent_energy_import kVAh, '
  || 'reactive_energy_export kvarh, reactive_energy_import kvarh, reactive_energy_lag kvarh, '
  || 'reactive_energy_lead kvarh',
  'every history quantity of elite_500 is shown, once');

SELECT pg_temp.is(
  pg_temp.unkeyed_scans(
    $$SELECT * FROM meter_stores.history WHERE meter_serial = 'SIM-445-0001'$$),
  NULL,
  'a meter''s history is found on an index, never by a scan of the entries');

ROLLBACK;
