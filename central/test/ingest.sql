-- api.ingest: what it stores, what it answers, and what it never does twice.

\ir lib/assert.sql
\set basic `cat ../contract/fixtures/batch.v1.basic.json`

BEGIN;

SELECT admin.create_collector('sqltest_a');
SELECT admin.create_collector('sqltest_b');

CREATE TEMP TABLE answers (name text PRIMARY KEY, answer jsonb);
INSERT INTO answers VALUES ('first', pg_temp.ingest_as('collector_sqltest_a', :'basic'));

SELECT pg_temp.is((SELECT answer FROM answers WHERE name = 'first') - 'first_received_at',
  '{"batch_id": "0b6f8d2e-5c1a-4e7b-9a3d-2f4c6e8a0b1c", "resent": false,
    "readings": {"received": 2, "inserted": 2, "duplicate": 0, "conflicting": 0},
    "missed_reads": {"received": 2, "inserted": 2, "duplicate": 0}}'::jsonb,
  'a new batch is stored, and the answer counts what was inserted');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s %s %s', meter_serial, register_key, value, unit), '; '
                     ORDER BY read_at)
   FROM store.readings),
  'SIM-445-0001 active_energy_import 1234.500 kWh; SIM-500-0001 active_energy_export 1234.500 kWh',
  'readings keep their value exactly as sent, scale included, import and export apart');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s %s %s %s %s %s', r.collector_id, r.raw_words, r.profile,
                            r.endpoint_host, r.endpoint_port, r.unit_id, r.read_at), '; '
                     ORDER BY r.read_at)
   FROM store.readings r),
  'sqltest_a {20480,17562} elite_440 10.0.0.21 502 1 2026-11-01 00:00:00+00; '
  || 'sqltest_a {0,0,18944,16531} elite_500 10.0.0.21 502 3 2026-11-01 00:00:01+00',
  'readings keep their raw words, where they came from, and the calling collector');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s %s %s %s %s', meter_serial, reason, exception_code, detail,
                            attempts, collector_id), '; ' ORDER BY read_at)
   FROM store.missed_reads),
  'SIM-445-0009 exception 11  3 sqltest_a; SIM-445-0010 unreachable  econnrefused 0 sqltest_a',
  'missed reads are stored with their reason');

SELECT pg_temp.is(
  (SELECT format('%s %s %s %s %s', collector_id, clock_source, clock_last_sync_at, readings,
                 missed_reads)
   FROM store.batches),
  'sqltest_a ntp 2026-11-01 00:00:12+00 2 2',
  'the batch is recorded with its clock status');

SELECT pg_temp.is(
  (SELECT format('%s %s %s %s %s %s %s %s %s', sent_at, backlog_events, backlog_bytes,
                 backlog_batches, backlog_oldest, backlog_max_bytes, backlog_refused,
                 backlog_discarded_files, backlog_quarantined)
   FROM store.uploads),
  '2026-11-01 00:05:00+00 4 412 1 2026-11-01 00:00:00+00 2000000000 0 0 0',
  'the upload is recorded with the backlog the collector reported');

INSERT INTO answers VALUES ('resent', pg_temp.ingest_as('collector_sqltest_a', :'basic'));

SELECT pg_temp.is((SELECT answer FROM answers WHERE name = 'resent') - 'first_received_at',
  '{"batch_id": "0b6f8d2e-5c1a-4e7b-9a3d-2f4c6e8a0b1c", "resent": true,
    "readings": {"received": 2, "inserted": 0, "duplicate": 2, "conflicting": 0},
    "missed_reads": {"received": 2, "inserted": 0, "duplicate": 2}}'::jsonb,
  'a resent batch is accepted, and nothing in it is stored twice');

SELECT pg_temp.is(
  (SELECT format('%s %s %s %s', (SELECT count(*) FROM store.readings),
                 (SELECT count(*) FROM store.missed_reads), (SELECT count(*) FROM store.batches),
                 (SELECT count(*) FROM store.uploads))),
  '2 2 1 2',
  'a resent batch adds an upload and nothing else');

SELECT pg_temp.is(
  pg_temp.ingest_as('collector_sqltest_a',
    jsonb_set(:'basic', '{batch_id}', '"11111111-1111-4111-8111-111111111111"')) -> 'readings',
  '{"received": 2, "inserted": 0, "duplicate": 2, "conflicting": 0}',
  'readings already stored are not stored again from another batch');

SELECT pg_temp.ok(
  pg_temp.ingest_error('collector_sqltest_b', :'basic') LIKE 'PT409: %another collector',
  'a batch id already sent by another collector is refused with 409');

SELECT pg_temp.ingest_as('collector_sqltest_b',
  pg_temp.changed(
    pg_temp.changed(:'basic', '{"path": ["batch_id"], "value": "22222222-2222-4222-8222-222222222222"}'),
    '{"path": ["readings"], "value": [{"endpoint": {"host": "10.0.0.30", "port": 502},
       "unit_id": 2, "meter_serial": "SIM-445-0002", "profile": "elite_440",
       "register_key": "active_energy_import", "timestamp": "2026-11-01T00:00:00Z",
       "raw_words": [0, 0], "value": "0.0", "unit": "Wh"}]}'));

SELECT pg_temp.is(
  (SELECT string_agg(format('%s:%s', meter_serial, collector_id), ' ' ORDER BY meter_serial)
   FROM store.readings),
  'SIM-445-0001:sqltest_a SIM-445-0002:sqltest_b SIM-500-0001:sqltest_a',
  'each reading belongs to the collector that called');

SELECT pg_temp.is(
  (SELECT collector_id FROM store.batches
   WHERE batch_id = '22222222-2222-4222-8222-222222222222'),
  'sqltest_b',
  'a batch belongs to the collector that called');

SELECT pg_temp.is(
  pg_temp.ingest_as('collector_sqltest_a',
    pg_temp.changed(
      pg_temp.changed(:'basic', '{"path": ["batch_id"], "value": "33333333-3333-4333-8333-333333333333"}'),
      '{"path": ["readings", 0, "value"], "value": "999.0"}')) -> 'readings',
  '{"received": 2, "inserted": 0, "duplicate": 1, "conflicting": 1}',
  'a reading that differs from the stored one under the same key is counted as conflicting');

SELECT pg_temp.is(
  (SELECT format('%s / %s',
     (SELECT value FROM store.readings WHERE meter_serial = 'SIM-445-0001'),
     (SELECT string_agg(format('%s %s', value, batch_id), ', ') FROM store.reading_conflicts))),
  '1234.500 / 999.0 33333333-3333-4333-8333-333333333333',
  'the stored reading is unchanged and the conflicting one is kept');

SELECT pg_temp.is(
  pg_temp.ingest_as('collector_sqltest_a',
    pg_temp.changed(
      pg_temp.changed(:'basic', '{"path": ["batch_id"], "value": "44444444-4444-4444-8444-444444444444"}'),
      '{"path": ["readings", 0, "timestamp"], "value": "2025-01-01T00:00:00Z"}')) -> 'readings',
  '{"received": 2, "inserted": 1, "duplicate": 1, "conflicting": 0}',
  'a reading taken almost two years ago is accepted');

SELECT pg_temp.ingest_as('collector_sqltest_a',
  pg_temp.changed(
    pg_temp.changed(
      pg_temp.changed(:'basic', '{"path": ["batch_id"], "value": "55555555-5555-4555-8555-555555555555"}'),
      '{"path": ["readings", 0, "value"], "value": "-123456789012345678901234.123456789012"}'),
    '{"path": ["readings", 0, "timestamp"], "value": "2026-10-01T00:00:00.123456Z"}'));

SELECT pg_temp.is(
  (SELECT value::text FROM store.readings WHERE read_at = '2026-10-01T00:00:00.123456Z'),
  '-123456789012345678901234.123456789012',
  'a 36-digit value is stored exactly, and a microsecond timestamp kept');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s.%s %s', table_name, column_name, data_type), '; '
                     ORDER BY table_name)
   FROM information_schema.columns
   WHERE table_schema = 'store' AND column_name = 'value'),
  'reading_conflicts.value numeric; readings.value numeric',
  'values are stored as numeric, never float');

SELECT pg_temp.ok(
  pg_temp.ingest_error('collector', :'basic') LIKE 'PT403: %',
  'the collector group role itself is refused with 403');

SELECT pg_temp.ok(
  pg_temp.ingest_error('postgres', :'basic') LIKE 'PT403: %',
  'even the owner, not acting as a collector, is refused with 403');

SELECT pg_temp.ok(pg_temp.sqlstate_as('postgres', q) = 'P0001', 'the owner is refused: ' || q)
FROM unnest(ARRAY[
  'UPDATE store.readings SET value = 0',
  'DELETE FROM store.readings',
  'TRUNCATE store.readings',
  'UPDATE store.missed_reads SET attempts = 0',
  'DELETE FROM store.missed_reads',
  'TRUNCATE store.missed_reads',
  'DELETE FROM store.reading_conflicts',
  'DELETE FROM store.batches',
  'DELETE FROM store.uploads'
]) q;

ROLLBACK;
