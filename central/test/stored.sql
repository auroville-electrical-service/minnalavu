-- api.ingest's stored entries and meter-clock reads: what it stores, what it
-- counts, what it keeps apart, and what it refuses.

\ir lib/assert.sql
\set basic `cat ../contract/fixtures/batch.v1.basic.json`

BEGIN;

SELECT admin.create_collector('sqltest_st');

CREATE FUNCTION pg_temp.renamed(batch jsonb, id text) RETURNS jsonb
LANGUAGE sql AS $$
  SELECT jsonb_set(batch, '{batch_id}', to_jsonb(id))
$$;

-- The basic batch with this id, and with these stored entries and meter-clock
-- reads in place of its own; no readings or missed reads.
CREATE FUNCTION pg_temp.copies(basic jsonb, id text, entries jsonb, clocks jsonb) RETURNS jsonb
LANGUAGE sql AS $$
  SELECT jsonb_set(jsonb_set(jsonb_set(jsonb_set(pg_temp.renamed(basic, id),
    '{readings}', '[]'), '{missed_reads}', '[]'), '{stored_entries}', entries),
    '{meter_clock_reads}', clocks)
$$;

CREATE TEMP TABLE answers (name text PRIMARY KEY, answer jsonb);
INSERT INTO answers VALUES ('first', pg_temp.ingest_as('collector_sqltest_st', :'basic'));

SELECT pg_temp.is(
  (SELECT answer -> 'stored_entries' || jsonb_build_object('clocks', answer -> 'meter_clock_reads')
   FROM answers WHERE name = 'first'),
  '{"received": 3, "inserted": 3, "duplicate": 0, "conflicting": 0,
    "clocks": {"received": 1, "inserted": 1, "duplicate": 0, "conflicting": 0}}'::jsonb,
  'a new batch''s stored entries and meter-clock reads are stored, and the answer counts them');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s %s %s %s %s %s %s', s.meter_serial, s.store, s.register_key,
                            s.meter_time, s.value, coalesce(s.interval_s::text, '-'), c.unit,
                            c.kind), '; ' ORDER BY s.store, s.meter_serial)
   FROM store.stored_entries s
   JOIN store.profile_stored c
     ON (c.profile, c.version, c.store, c.register_key)
        = (s.profile, s.profile_version, s.store, s.register_key)),
  'SIM-445-0001 history active_energy_import 2026-11-01 00:00:00 1234.5 - kWh cumulative; '
  || 'SIM-500-0001 snapshot active_energy_export 2026-11-01 00:00:00 1234.5 - kWh cumulative; '
  || 'SIM-445-0001 load_survey active_energy_import 2026-10-31 23:30:00 0.25 1800 kWh interval',
  'stored entries keep the meter''s stamp, no zone, and their value exactly as sent, and take '
  || 'their unit and kind from their profile version''s stored quantity');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s %s %s %s %s %s %s %s %s', s.profile, s.profile_version,
                            s.product_code, s.slot, s.copied_at, coalesce(s.request_id::text, '-'),
                            s.endpoint_host, s.endpoint_port, s.unit_id, s.collector_id),
                     '; ' ORDER BY s.copied_at)
   FROM store.stored_entries s),
  'elite_440 2 ELITE440-445 1 2026-11-01 00:00:04+00 - 10.0.0.21 502 1 sqltest_st; '
  || 'elite_440 2 ELITE440-445 1 2026-11-01 00:00:05+00 - 10.0.0.21 502 1 sqltest_st; '
  || 'elite_500 2 E500C-5102 1 2026-11-01 00:00:06+00 - 10.0.0.21 502 3 sqltest_st',
  'stored entries keep their profile version, slot, copy time, where they came from, and the '
  || 'calling collector');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s %s %s %s %s %s %s %s', m.collector_id, m.endpoint_host,
                            m.endpoint_port, m.unit_id, m.collector_at, m.meter_serial,
                            m.profile, m.profile_version, m.meter_time), '; ')
   FROM store.meter_clock_reads m),
  'sqltest_st 10.0.0.21 502 1 2026-11-01 00:00:04+00 SIM-445-0001 elite_440 2 '
  || '2026-11-01 00:28:49',
  'a meter-clock read keeps both clocks raw: the meter''s with no zone, beside the collector''s');

INSERT INTO answers VALUES ('resent', pg_temp.ingest_as('collector_sqltest_st', :'basic'));

SELECT pg_temp.is(
  (SELECT answer -> 'stored_entries' || jsonb_build_object('clocks', answer -> 'meter_clock_reads')
   FROM answers WHERE name = 'resent'),
  '{"received": 3, "inserted": 0, "duplicate": 3, "conflicting": 0,
    "clocks": {"received": 1, "inserted": 0, "duplicate": 1, "conflicting": 0}}'::jsonb,
  'a resent batch''s stored entries and meter-clock reads are duplicates');

SELECT pg_temp.is(
  (SELECT format('%s %s %s', (SELECT count(*) FROM store.stored_entries),
                 (SELECT count(*) FROM store.stored_entry_conflicts),
                 (SELECT count(*) FROM store.meter_clock_reads))),
  '3 0 1',
  'and nothing of them is stored twice');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s %s %s %s %s', stored_entries_inserted,
                            stored_entries_duplicate, stored_entries_conflicting,
                            meter_clock_reads_inserted, meter_clock_reads_duplicate,
                            meter_clock_reads_conflicting), '; ' ORDER BY upload_id)
   FROM store.uploads WHERE collector_id = 'sqltest_st'),
  '3 0 0 1 0 0; 0 3 0 0 1 0',
  'each upload counts its stored entries and meter-clock reads');

-- The same entries copied again on a later night: another batch, slot, copy
-- time and address.
SELECT pg_temp.is(
  pg_temp.ingest_as('collector_sqltest_st', pg_temp.copies(:'basic',
    'd1d1d1d1-d1d1-4d1d-8d1d-d1d1d1d1d1d1',
    (SELECT jsonb_agg(jsonb_set(jsonb_set(jsonb_set(e, '{slot}', '2'),
                                          '{copied_at}', '"2026-11-02T02:00:00Z"'),
                                '{endpoint,host}', '"10.0.0.99"'))
     FROM jsonb_array_elements(:'basic'::jsonb -> 'stored_entries') e),
    '[]')) -> 'stored_entries',
  '{"received": 3, "inserted": 0, "duplicate": 3, "conflicting": 0}',
  'an entry copied again, from another slot, time or address, saying the same, is a duplicate');

SELECT pg_temp.is(
  (SELECT string_agg(DISTINCT format('%s %s', slot, endpoint_host), ', ')
   FROM store.stored_entries),
  '1 10.0.0.21',
  'and the entry as first copied stands');

-- A conflict: another value under a taken key.
CREATE TEMP TABLE differing (batch jsonb);
INSERT INTO differing SELECT pg_temp.changed(
  pg_temp.renamed(:'basic', 'd2d2d2d2-d2d2-4d2d-8d2d-d2d2d2d2d2d2'),
  '{"path": ["stored_entries", 0, "value"], "value": "1234.6"}');

SELECT pg_temp.is(
  pg_temp.ingest_as('collector_sqltest_st', (SELECT batch FROM differing)) -> 'stored_entries',
  '{"received": 3, "inserted": 0, "duplicate": 2, "conflicting": 1}',
  'an entry that differs from the stored one under the same key is counted as conflicting');

SELECT pg_temp.is(
  (SELECT format('%s / %s',
     (SELECT value FROM store.stored_entries WHERE store = 'history'),
     (SELECT string_agg(format('%s %s %s', store, value, batch_id), ', ')
      FROM store.stored_entry_conflicts))),
  '1234.5 / history 1234.6 d2d2d2d2-d2d2-4d2d-8d2d-d2d2d2d2d2d2',
  'the stored entry is unchanged and the conflicting one is kept');

SELECT pg_temp.is(
  pg_temp.ingest_as('collector_sqltest_st', (SELECT batch FROM differing)) -> 'stored_entries',
  '{"received": 3, "inserted": 0, "duplicate": 2, "conflicting": 1}',
  'a resent conflicting batch is counted as conflicting again');

SELECT pg_temp.is(
  (SELECT count(*) FROM store.stored_entry_conflicts),
  1::bigint,
  'but its conflict is kept once');

SELECT pg_temp.is(
  pg_temp.ingest_as('collector_sqltest_st', pg_temp.changed(
    pg_temp.renamed(:'basic', 'd3d3d3d3-d3d3-4d3d-8d3d-d3d3d3d3d3d3'),
    '{"path": ["stored_entries", 1, "interval_s"], "value": 900}')) -> 'stored_entries',
  '{"received": 3, "inserted": 0, "duplicate": 2, "conflicting": 1}',
  'a load-survey entry under a taken key with another interval is conflicting');

SELECT pg_temp.is(
  pg_temp.ingest_as('collector_sqltest_st', pg_temp.changed(
    pg_temp.renamed(:'basic', 'd4d4d4d4-d4d4-4d4d-8d4d-d4d4d4d4d4d4'),
    '{"path": ["stored_entries", 0, "meter_time"], "value": "2026-12-01T00:00:00"}'))
    -> 'stored_entries',
  '{"received": 3, "inserted": 1, "duplicate": 2, "conflicting": 0}',
  'an entry under another stamp is a new entry, whatever its slot');

-- Meter-clock reads: another meter time at a taken read is counted, not kept.
SELECT pg_temp.is(
  pg_temp.ingest_as('collector_sqltest_st', pg_temp.changed(
    pg_temp.renamed(:'basic', 'd5d5d5d5-d5d5-4d5d-8d5d-d5d5d5d5d5d5'),
    '{"path": ["meter_clock_reads", 0, "meter_time"], "value": "2026-11-01T00:28:50"}'))
    -> 'meter_clock_reads',
  '{"received": 1, "inserted": 0, "duplicate": 0, "conflicting": 1}',
  'a meter-clock read that differs from the stored one at its address and time is conflicting');

SELECT pg_temp.is(
  (SELECT string_agg(meter_time::text, ', ') FROM store.meter_clock_reads),
  '2026-11-01 00:28:49',
  'and the stored read stands');

SELECT pg_temp.is(
  pg_temp.ingest_as('collector_sqltest_st', pg_temp.changed(
    pg_temp.renamed(:'basic', 'd6d6d6d6-d6d6-4d6d-8d6d-d6d6d6d6d6d6'),
    '{"path": ["meter_clock_reads", 0, "collector_at"], "value": "2026-11-02T02:00:00.000001Z"}'))
    -> 'meter_clock_reads',
  '{"received": 1, "inserted": 1, "duplicate": 0, "conflicting": 0}',
  'a meter-clock read at another time is a new read');

-- Late copies, found by arrival: an entry copied a month ago that arrived
-- then, and one older by the meter's stamp that arrives now.
SELECT admin.create_collector('sqltest_st_late');
INSERT INTO store.batches VALUES ('e0e0e0e0-e0e0-4e0e-8e0e-e0e0e0e0e0e0', 'sqltest_st_late',
  now() - interval '30 days', 'ntp', NULL, 0, 0);
INSERT INTO store.stored_entries
  (meter_serial, store, register_key, meter_time, value, profile, profile_version, product_code,
   slot, copied_at, endpoint_host, endpoint_port, unit_id, collector_id, batch_id)
VALUES ('SIM-445-0060', 'history', 'active_energy_import', '2026-10-01T00:00:00', 900,
        'elite_440', 2, 'ELITE440-445', 1, now() - interval '30 days', '10.0.0.60', 502, 1,
        'sqltest_st_late', 'e0e0e0e0-e0e0-4e0e-8e0e-e0e0e0e0e0e0');

SELECT pg_temp.is(
  pg_temp.ingest_as('collector_sqltest_st_late', pg_temp.copies(:'basic',
    'e1e1e1e1-e1e1-4e1e-8e1e-e1e1e1e1e1e1',
    '[{"endpoint": {"host": "10.0.0.60", "port": 502}, "unit_id": 1,
       "meter_serial": "SIM-445-0060", "product_code": "ELITE440-445", "profile": "elite_440",
       "profile_version": 2, "store": "history", "meter_time": "2026-09-01T00:00:00",
       "register_key": "active_energy_import", "value": "800", "slot": 2,
       "copied_at": "2026-10-01T01:00:00Z"}]',
    '[]')) -> 'stored_entries',
  '{"received": 1, "inserted": 1, "duplicate": 0, "conflicting": 0}',
  'an entry weeks old by both clocks is accepted');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s', s.meter_time, s.value), '; ')
   FROM store.batches b JOIN store.stored_entries s USING (batch_id)
   WHERE b.collector_id = 'sqltest_st_late' AND b.received_at > now() - interval '1 day'),
  '2026-09-01 00:00:00 800',
  'a late entry is found by its batch''s arrival, not by its stamp');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s', meter_time, (received_at = now())::text), '; ' ORDER BY meter_time)
   FROM health.stored_entries WHERE meter_serial = 'SIM-445-0060'),
  '2026-09-01 00:00:00 true; 2026-10-01 00:00:00 false',
  'health.stored_entries shows each entry with its batch''s arrival');

-- OFFSET 0 keeps the step a lookup, as health.energy_drops does.
SELECT pg_temp.is(
  pg_temp.unkeyed_scans($$
    SELECT s.* FROM store.batches b
    CROSS JOIN LATERAL (SELECT * FROM store.stored_entries q WHERE q.batch_id = b.batch_id
                        OFFSET 0) s
    WHERE b.received_at > now() - interval '1 day'$$),
  NULL,
  'entries are found by their batch''s arrival on an index, never by a scan of them');

-- The catalog: an entry's quantity must be one its profile version holds in
-- its store.
SELECT pg_temp.is(
  pg_temp.ingest_error('collector_sqltest_st', pg_temp.changed(
    pg_temp.renamed(:'basic', 'f0f0f0f0-f0f0-4f0f-8f0f-f0f0f0f0f0f0'),
    '{"path": ["stored_entries", 2, "register_key"], "value": "net_energy"}')),
  'PT422: batch rejected: batch.stored_entries[2].register_key is not a snapshot quantity of '
  || 'profile elite_500 version 2',
  'an entry of a quantity its profile version does not hold is rejected, naming the field');

SELECT pg_temp.is(
  pg_temp.ingest_error('collector_sqltest_st', pg_temp.copies(:'basic',
    'f1f1f1f1-f1f1-4f1f-8f1f-f1f1f1f1f1f1',
    '[{"endpoint": {"host": "10.0.0.21", "port": 502}, "unit_id": 3,
       "meter_serial": "SIM-500-0001", "product_code": "E500C-5102", "profile": "elite_500",
       "profile_version": 2, "store": "load_survey", "meter_time": "2026-10-31T23:45:00",
       "interval_s": 900, "register_key": "active_energy_import_l1", "value": "12.5", "slot": 1,
       "copied_at": "2026-11-01T00:00:06Z"}]',
    '[]')),
  'PT422: batch rejected: batch.stored_entries[0].register_key is not a load_survey quantity of '
  || 'profile elite_500 version 2',
  'a cumulative quantity is refused as a load-survey entry');

SELECT pg_temp.is(
  pg_temp.ingest_error('collector_sqltest_st', pg_temp.copies(:'basic',
    'f2f2f2f2-f2f2-4f2f-8f2f-f2f2f2f2f2f2',
    '[{"endpoint": {"host": "10.0.0.21", "port": 502}, "unit_id": 1,
       "meter_serial": "SIM-445-0001", "product_code": "ELITE440-445", "profile": "elite_440",
       "profile_version": 2, "store": "history", "meter_time": "2026-11-01T00:00:00",
       "register_key": "voltage_l1", "value": "230.1", "slot": 1,
       "copied_at": "2026-11-01T00:00:04Z"}]',
    '[]')),
  'PT422: batch rejected: batch.stored_entries[0].register_key is not a history quantity of '
  || 'profile elite_440 version 2',
  'a load-survey quantity is refused as a history entry');

SELECT pg_temp.is(
  pg_temp.ingest_error('collector_sqltest_st', pg_temp.changed(
    pg_temp.renamed(:'basic', 'f3f3f3f3-f3f3-4f3f-8f3f-f3f3f3f3f3f3'),
    '{"path": ["stored_entries", 1, "profile_version"], "value": 9}')),
  'PT503: batch.stored_entries[1]: profile elite_440 version 9 is not loaded in the store',
  'an entry under a profile version not loaded is refused with 503, so the collector sends it again');

SELECT pg_temp.is(
  pg_temp.ingest_error('collector_sqltest_st', pg_temp.changed(
    pg_temp.renamed(:'basic', 'f3f3f3f3-f3f3-4f3f-8f3f-f3f3f3f3f3f3'),
    '{"path": ["meter_clock_reads", 0, "profile"], "value": "elite_999"}')),
  'PT503: batch.meter_clock_reads[0]: profile elite_999 version 2 is not loaded in the store',
  'so is a meter-clock read');

SELECT pg_temp.is(
  (SELECT count(*) FROM store.batches WHERE batch_id::text ~ '^f[0-3]'),
  0::bigint,
  'and nothing of their batches is stored');

SELECT pg_temp.is(pg_temp.sqlstate_as('postgres', q), '23503', 'the store refuses: ' || q)
FROM unnest(ARRAY[
  $q$INSERT INTO store.stored_entries
       (meter_serial, store, register_key, meter_time, value, interval_s, profile,
        profile_version, product_code, slot, copied_at, endpoint_host, endpoint_port, unit_id,
        collector_id, batch_id)
     SELECT meter_serial, 'load_survey', 'active_energy_import_l1', meter_time, value, 900,
            profile, profile_version, product_code, slot, copied_at, endpoint_host,
            endpoint_port, unit_id, collector_id, batch_id
     FROM store.stored_entries WHERE profile = 'elite_500' LIMIT 1$q$,
  $q$INSERT INTO store.stored_entries
       (meter_serial, store, register_key, meter_time, value, profile, profile_version,
        product_code, slot, copied_at, endpoint_host, endpoint_port, unit_id, collector_id,
        batch_id)
     SELECT meter_serial, store, 'net_energy', meter_time, value, profile, profile_version,
            product_code, slot, copied_at, endpoint_host, endpoint_port, unit_id, collector_id,
            batch_id
     FROM store.stored_entries WHERE store = 'history' LIMIT 1$q$,
  $q$INSERT INTO store.meter_clock_reads
     SELECT collector_id, endpoint_host, endpoint_port, unit_id, collector_at + interval '1 day',
            meter_serial, profile, 9, meter_time, batch_id
     FROM store.meter_clock_reads LIMIT 1$q$
]) q;

SELECT pg_temp.is(pg_temp.sqlstate_as('postgres', q), '23514', 'the store refuses: ' || q)
FROM unnest(ARRAY[
  $q$INSERT INTO store.stored_entries
       (meter_serial, store, register_key, meter_time, value, interval_s, profile,
        profile_version, product_code, slot, copied_at, endpoint_host, endpoint_port, unit_id,
        collector_id, batch_id)
     SELECT meter_serial, store, register_key, meter_time + interval '1 day', value, 1800,
            profile, profile_version, product_code, slot, copied_at, endpoint_host,
            endpoint_port, unit_id, collector_id, batch_id
     FROM store.stored_entries WHERE store = 'history' LIMIT 1$q$,
  $q$INSERT INTO store.stored_entries
       (meter_serial, store, register_key, meter_time, value, profile, profile_version,
        product_code, slot, copied_at, endpoint_host, endpoint_port, unit_id, collector_id,
        batch_id)
     SELECT meter_serial, store, register_key, meter_time + interval '1 day', value, profile,
            profile_version, product_code, slot, copied_at, endpoint_host, endpoint_port,
            unit_id, collector_id, batch_id
     FROM store.stored_entries WHERE store = 'load_survey' LIMIT 1$q$
]) q;

SELECT pg_temp.is(
  (SELECT string_agg(format('%s.%s', table_name, column_name), ', '
                     ORDER BY table_name, column_name)
   FROM information_schema.columns
   WHERE table_schema = 'store'
     AND table_name IN ('stored_entries', 'stored_entry_conflicts', 'meter_clock_reads')
     AND column_name IN ('raw_words', 'unit', 'kind', 'history_reason_raw', 'offset_s')),
  NULL,
  'stored entries and meter-clock reads carry no raw words, unit, kind, reason or offset');

SELECT pg_temp.ok(pg_temp.sqlstate_as('postgres', q) = 'P0001', 'the owner is refused: ' || q)
FROM unnest(ARRAY[
  'UPDATE store.stored_entries SET value = 0',
  'DELETE FROM store.stored_entries',
  'TRUNCATE store.stored_entries',
  'UPDATE store.stored_entry_conflicts SET value = 0',
  'DELETE FROM store.stored_entry_conflicts',
  'TRUNCATE store.stored_entry_conflicts',
  $q$UPDATE store.meter_clock_reads SET meter_time = '2000-01-01'$q$,
  'DELETE FROM store.meter_clock_reads',
  'TRUNCATE store.meter_clock_reads'
]) q;

ROLLBACK;
