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
    "missed_reads": {"received": 2, "inserted": 2, "duplicate": 0},
    "firmware_reads": {"received": 0, "inserted": 0, "duplicate": 0, "conflicting": 0}}'::jsonb,
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
    "missed_reads": {"received": 2, "inserted": 0, "duplicate": 2},
    "firmware_reads": {"received": 0, "inserted": 0, "duplicate": 0, "conflicting": 0}}'::jsonb,
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
       "unit_id": 2, "meter_serial": "SIM-445-0002", "product_code": "ELITE440-445",
       "profile": "elite_440", "register_key": "active_energy_import",
       "timestamp": "2026-11-01T00:00:00Z",
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
  (SELECT string_agg(product_code, ' ' ORDER BY product_code) FROM store.readings
   WHERE batch_id = '0b6f8d2e-5c1a-4e7b-9a3d-2f4c6e8a0b1c'),
  'E500C-5102 ELITE440-445',
  'the basic batch''s readings keep their product codes');

SELECT pg_temp.is(
  pg_temp.ingest_error('collector_sqltest_a',
    pg_temp.changed(
      pg_temp.changed(:'basic', '{"path": ["batch_id"], "value": "5a5a5a5a-5a5a-45a5-85a5-5a5a5a5a5a5a"}'),
      '{"path": ["readings", 1, "product_code"], "delete": true}')),
  'PT422: batch rejected: batch.readings[1] is missing product_code',
  'a reading without a product code is rejected, naming the field');

SELECT pg_temp.is(
  (SELECT count(*) FROM store.batches WHERE batch_id = '5a5a5a5a-5a5a-45a5-85a5-5a5a5a5a5a5a'),
  0::bigint,
  'and nothing of its batch is stored');

SELECT pg_temp.is(
  pg_temp.sqlstate_as('postgres', $$
    INSERT INTO store.readings
      (meter_serial, register_key, read_at, value, unit, raw_words, profile, endpoint_host,
       endpoint_port, unit_id, product_code, collector_id, batch_id)
    SELECT meter_serial, register_key, read_at + interval '1 second', value, unit, raw_words,
           profile, endpoint_host, endpoint_port, unit_id, NULL, collector_id, batch_id
    FROM store.readings LIMIT 1$$),
  '23502',
  'the store refuses a reading row without a product code');

-- A batch of one reading, with the product code read, and missed reads at
-- addresses the basic batch's are not at.
CREATE TEMP TABLE coded (batch jsonb);
INSERT INTO coded SELECT pg_temp.changed(pg_temp.changed(pg_temp.changed(:'basic',
  '{"path": ["batch_id"], "value": "66666666-6666-4666-8666-666666666666"}'),
  '{"path": ["readings"], "value": [{"endpoint": {"host": "10.0.0.40", "port": 502},
     "unit_id": 4, "meter_serial": "SIM-445-0004", "product_code": "ELITE440-445",
     "profile": "elite_440", "register_key": "active_energy_import",
     "timestamp": "2026-11-02T00:00:00Z", "raw_words": [0, 0], "value": "0.0", "unit": "Wh"}]}'),
  '{"path": ["missed_reads"], "value": [
     {"endpoint": {"host": "10.0.0.40", "port": 502}, "unit_id": 5, "meter_serial": null,
      "profile": "elite_440", "register_key": "active_energy_import",
      "timestamp": "2026-11-02T00:00:00Z", "reason": "timeout", "exception_code": null,
      "detail": null, "attempts": 3, "raw_words": null},
     {"endpoint": {"host": "10.0.0.40", "port": 502}, "unit_id": 6, "meter_serial": null,
      "profile": "elite_440", "register_key": "active_energy_import",
      "timestamp": "2026-11-02T00:00:00Z", "reason": "timeout", "exception_code": null,
      "detail": null, "attempts": 3, "raw_words": null},
     {"endpoint": {"host": "10.0.0.41", "port": 502}, "unit_id": 5, "meter_serial": "SIM-445-0007",
      "profile": "elite_440", "register_key": "active_energy_import",
      "timestamp": "2026-11-02T00:00:00Z", "reason": "exception", "exception_code": 2,
      "detail": null, "attempts": 3, "raw_words": null},
     {"endpoint": {"host": "10.0.0.42", "port": 502}, "unit_id": 5, "meter_serial": "SIM-445-0007",
      "profile": "elite_440", "register_key": "active_energy_import",
      "timestamp": "2026-11-02T00:00:00Z", "reason": "exception", "exception_code": 2,
      "detail": null, "attempts": 3, "raw_words": null}]}');

SELECT pg_temp.is(
  pg_temp.ingest_as('collector_sqltest_a', (SELECT batch FROM coded)) - 'first_received_at',
  '{"batch_id": "66666666-6666-4666-8666-666666666666", "resent": false,
    "readings": {"received": 1, "inserted": 1, "duplicate": 0, "conflicting": 0},
    "missed_reads": {"received": 4, "inserted": 4, "duplicate": 0},
    "firmware_reads": {"received": 0, "inserted": 0, "duplicate": 0, "conflicting": 0}}'::jsonb,
  'missed reads at different addresses are each stored, with or without the serial read');

SELECT pg_temp.is(
  (SELECT product_code FROM store.readings WHERE meter_serial = 'SIM-445-0004'),
  'ELITE440-445',
  'a reading keeps the product code read');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s %s', endpoint_host, unit_id, coalesce(meter_serial, 'NULL')),
                     '; ' ORDER BY endpoint_host, unit_id)
   FROM store.missed_reads WHERE batch_id = '66666666-6666-4666-8666-666666666666'),
  '10.0.0.40 5 NULL; 10.0.0.40 6 NULL; 10.0.0.41 5 SIM-445-0007; 10.0.0.42 5 SIM-445-0007',
  'a missed read keeps the serial read in its round, or none');

SELECT pg_temp.is(
  pg_temp.ingest_as('collector_sqltest_a',
    jsonb_set((SELECT batch FROM coded), '{batch_id}', '"77777777-7777-4777-8777-777777777777"'))
    -> 'missed_reads',
  '{"received": 4, "inserted": 0, "duplicate": 4}',
  'a missed read already stored at its address is not stored again, whatever serial it carries');

SELECT pg_temp.is(
  pg_temp.ingest_as('collector_sqltest_b',
    jsonb_set((SELECT batch FROM coded), '{batch_id}', '"88888888-8888-4888-8888-888888888888"'))
    -> 'missed_reads',
  '{"received": 4, "inserted": 4, "duplicate": 0}',
  'the same address under another collector is another address');

SELECT pg_temp.is(
  pg_temp.ingest_as('collector_sqltest_a',
    pg_temp.changed(
      jsonb_set((SELECT batch FROM coded), '{batch_id}', '"99999999-9999-4999-8999-999999999999"'),
      '{"path": ["readings", 0, "product_code"], "value": "ELITE440-446"}')) -> 'readings',
  '{"received": 1, "inserted": 0, "duplicate": 0, "conflicting": 1}',
  'a reading whose product code differs from the stored one''s is conflicting');

SELECT pg_temp.is(
  (SELECT product_code FROM store.reading_conflicts
   WHERE batch_id = '99999999-9999-4999-8999-999999999999'),
  'ELITE440-446',
  'the conflicting reading keeps its product code');

-- Firmware reads: a batch of the basic batch's events and two meters' names,
-- one of which the meter did not give in full.
CREATE TEMP TABLE named (batch jsonb);
INSERT INTO named SELECT pg_temp.changed(pg_temp.changed(:'basic',
  '{"path": ["batch_id"], "value": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}'),
  '{"path": ["firmware_reads"], "value": [
     {"endpoint": {"host": "10.0.0.21", "port": 502}, "unit_id": 1,
      "meter_serial": "SIM-445-0001", "product_code": "ELITE440-445",
      "timestamp": "2026-11-01T00:00:00Z", "software": "SIM-SW44", "firmware_1": "SIM-F1",
      "firmware_2": "SIM-F2", "modbus_version": "0B03"},
     {"endpoint": {"host": "10.0.0.21", "port": 502}, "unit_id": 3,
      "meter_serial": "SIM-500-0001", "product_code": "E500C-5102",
      "timestamp": "2026-11-01T00:00:01Z", "software": "SIM-SW5", "firmware_1": null,
      "firmware_2": null, "modbus_version": "00FF"}]}');

SELECT pg_temp.is(
  pg_temp.ingest_as('collector_sqltest_a', (SELECT batch FROM named)) -> 'firmware_reads',
  '{"received": 2, "inserted": 2, "duplicate": 0, "conflicting": 0}',
  'a batch''s firmware reads are stored, and the answer counts them');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s %s %s %s %s %s %s:%s %s %s %s', meter_serial, product_code,
                            read_at, software, coalesce(firmware_1, 'NULL'),
                            coalesce(firmware_2, 'NULL'), modbus_version, endpoint_host,
                            endpoint_port, unit_id, collector_id, batch_id), '; '
                     ORDER BY read_at)
   FROM store.firmware_reads),
  'SIM-445-0001 ELITE440-445 2026-11-01 00:00:00+00 SIM-SW44 SIM-F1 SIM-F2 0B03 10.0.0.21:502 1 '
  || 'sqltest_a aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa; '
  || 'SIM-500-0001 E500C-5102 2026-11-01 00:00:01+00 SIM-SW5 NULL NULL 00FF 10.0.0.21:502 3 '
  || 'sqltest_a aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'firmware reads keep their names as sent, a name not given as NULL, where and when they were '
  || 'read, the calling collector and their batch');

SELECT pg_temp.is(
  pg_temp.ingest_as('collector_sqltest_a', (SELECT batch FROM named)) -> 'firmware_reads',
  '{"received": 2, "inserted": 0, "duplicate": 2, "conflicting": 0}',
  'a resent batch''s firmware reads are not stored twice');

SELECT pg_temp.is(
  pg_temp.ingest_as('collector_sqltest_a',
    jsonb_set((SELECT batch FROM named), '{batch_id}', '"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"'))
    -> 'firmware_reads',
  '{"received": 2, "inserted": 0, "duplicate": 2, "conflicting": 0}',
  'firmware reads already stored are not stored again from another batch');

SELECT pg_temp.is(
  pg_temp.ingest_as('collector_sqltest_a',
    pg_temp.changed(
      jsonb_set((SELECT batch FROM named), '{batch_id}', '"cccccccc-cccc-4ccc-8ccc-cccccccccccc"'),
      '{"path": ["firmware_reads", 0, "software"], "value": "SIM-SW45"}')) -> 'firmware_reads',
  '{"received": 2, "inserted": 0, "duplicate": 1, "conflicting": 1}',
  'a firmware read that differs from the stored one at its address and time is conflicting');

SELECT pg_temp.is(
  (SELECT string_agg(software, ' ' ORDER BY software) FROM store.firmware_reads),
  'SIM-SW44 SIM-SW5',
  'and the stored firmware read is unchanged');

SELECT pg_temp.is(
  pg_temp.ingest_as('collector_sqltest_b',
    jsonb_set((SELECT batch FROM named), '{batch_id}', '"dddddddd-dddd-4ddd-8ddd-dddddddddddd"'))
    -> 'firmware_reads',
  '{"received": 2, "inserted": 2, "duplicate": 0, "conflicting": 0}',
  'the same address and time under another collector is another firmware read');

SELECT pg_temp.is(
  pg_temp.ingest_as('collector_sqltest_a',
    pg_temp.changed(
      pg_temp.changed(
        jsonb_set((SELECT batch FROM named), '{batch_id}', '"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"'),
        '{"path": ["firmware_reads", 0, "timestamp"], "value": "2025-01-01T00:00:00Z"}'),
      '{"path": ["firmware_reads", 1, "timestamp"], "value": "2025-01-01T00:00:00Z"}'))
    -> 'firmware_reads',
  '{"received": 2, "inserted": 2, "duplicate": 0, "conflicting": 0}',
  'firmware reads taken almost two years ago are accepted');

SELECT pg_temp.is(
  pg_temp.ingest_error('collector_sqltest_a',
    pg_temp.changed(
      jsonb_set((SELECT batch FROM named), '{batch_id}', '"ffffffff-ffff-4fff-8fff-ffffffffffff"'),
      '{"path": ["firmware_reads", 1, "firmware_2"], "value": "SIM-F2 "}')),
  'PT422: batch rejected: batch.firmware_reads[1].firmware_2 must be printable ASCII with no '
  || 'leading or trailing space',
  'a firmware read with a malformed name is rejected, naming the field');

SELECT pg_temp.is(
  (SELECT count(*) FROM store.batches WHERE batch_id = 'ffffffff-ffff-4fff-8fff-ffffffffffff'),
  0::bigint,
  'and nothing of its batch is stored');

SELECT pg_temp.is(
  pg_temp.sqlstate_as('postgres', $$
    INSERT INTO store.firmware_reads
    SELECT meter_serial, NULL, read_at + interval '1 second', software, firmware_1, firmware_2,
           modbus_version, endpoint_host, endpoint_port, unit_id, collector_id, batch_id
    FROM store.firmware_reads LIMIT 1$$),
  '23502',
  'the store refuses a firmware read without a product code');

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
  'DELETE FROM store.uploads',
  $q$UPDATE store.firmware_reads SET software = 'SIM-SW99'$q$,
  'DELETE FROM store.firmware_reads',
  'TRUNCATE store.firmware_reads'
]) q;

ROLLBACK;
