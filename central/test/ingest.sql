-- api.ingest: what it stores, what it answers, and what it never does twice.

\ir lib/assert.sql
\set basic `cat ../contract/fixtures/batch.v1.basic.json`
\set p440 `cat ../contract/profiles/elite_440.json`

BEGIN;

SELECT admin.create_collector('sqltest_a');
SELECT admin.create_collector('sqltest_b');

CREATE TEMP TABLE answers (name text PRIMARY KEY, answer jsonb);
INSERT INTO answers VALUES ('first', pg_temp.ingest_as('collector_sqltest_a', :'basic'));

SELECT pg_temp.is((SELECT answer FROM answers WHERE name = 'first') - 'first_received_at',
  '{"batch_id": "0b6f8d2e-5c1a-4e7b-9a3d-2f4c6e8a0b1c", "resent": false,
    "readings": {"received": 2, "inserted": 2, "duplicate": 0, "conflicting": 0},
    "missed_reads": {"received": 2, "inserted": 2, "duplicate": 0},
    "firmware_reads": {"received": 0, "inserted": 0, "duplicate": 0, "conflicting": 0},
    "clock_checks": {"received": 0, "inserted": 0, "duplicate": 0, "conflicting": 0},
    "latency": {"received": 0, "inserted": 0, "duplicate": 0, "conflicting": 0}}'::jsonb,
  'a new batch is stored, and the answer counts what was inserted');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s %s %s %s', r.meter_serial, r.register_key, r.value, c.unit,
                            c.kind), '; ' ORDER BY r.read_at)
   FROM store.readings r
   JOIN store.profile_registers c
     ON (c.profile, c.version, c.register_key) = (r.profile, r.profile_version, r.register_key)),
  'SIM-445-0001 active_energy_import 1234.5 kWh cumulative; '
  || 'SIM-500-0001 active_energy_export 1234.5 kWh cumulative',
  'readings keep their value exactly as sent, import and export apart, and take their unit and '
  || 'kind from their profile version');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s %s %s %s %s %s', r.collector_id, r.profile,
                            r.profile_version, r.endpoint_host, r.endpoint_port, r.unit_id,
                            r.read_at), '; ' ORDER BY r.read_at)
   FROM store.readings r),
  'sqltest_a elite_440 1 10.0.0.21 502 1 2026-11-01 00:00:00+00; '
  || 'sqltest_a elite_500 1 10.0.0.21 502 3 2026-11-01 00:00:01+00',
  'readings keep their profile version, where they came from, and the calling collector');

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
    "firmware_reads": {"received": 0, "inserted": 0, "duplicate": 0, "conflicting": 0},
    "clock_checks": {"received": 0, "inserted": 0, "duplicate": 0, "conflicting": 0},
    "latency": {"received": 0, "inserted": 0, "duplicate": 0, "conflicting": 0}}'::jsonb,
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
       "profile": "elite_440", "profile_version": 1, "register_key": "active_energy_import",
       "timestamp": "2026-11-01T00:00:00Z",
       "value": "0.0"}]}'));

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
  '1234.5 / 999.0 33333333-3333-4333-8333-333333333333',
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
      (meter_serial, register_key, read_at, value, profile, profile_version, endpoint_host,
       endpoint_port, unit_id, product_code, collector_id, batch_id)
    SELECT meter_serial, register_key, read_at + interval '1 second', value, profile,
           profile_version, endpoint_host, endpoint_port, unit_id, NULL, collector_id, batch_id
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
     "profile": "elite_440", "profile_version": 1, "register_key": "active_energy_import",
     "timestamp": "2026-11-02T00:00:00Z", "value": "0.0"}]}'),
  '{"path": ["missed_reads"], "value": [
     {"endpoint": {"host": "10.0.0.40", "port": 502}, "unit_id": 5, "meter_serial": null,
      "profile": "elite_440", "profile_version": 1, "register_key": "active_energy_import",
      "timestamp": "2026-11-02T00:00:00Z", "reason": "timeout", "exception_code": null,
      "detail": null, "attempts": 3, "raw_words": null},
     {"endpoint": {"host": "10.0.0.40", "port": 502}, "unit_id": 6, "meter_serial": null,
      "profile": "elite_440", "profile_version": 1, "register_key": "active_energy_import",
      "timestamp": "2026-11-02T00:00:00Z", "reason": "timeout", "exception_code": null,
      "detail": null, "attempts": 3, "raw_words": null},
     {"endpoint": {"host": "10.0.0.41", "port": 502}, "unit_id": 5, "meter_serial": "SIM-445-0007",
      "profile": "elite_440", "profile_version": 1, "register_key": "active_energy_import",
      "timestamp": "2026-11-02T00:00:00Z", "reason": "exception", "exception_code": 2,
      "detail": null, "attempts": 3, "raw_words": null},
     {"endpoint": {"host": "10.0.0.42", "port": 502}, "unit_id": 5, "meter_serial": "SIM-445-0007",
      "profile": "elite_440", "profile_version": 1, "register_key": "active_energy_import",
      "timestamp": "2026-11-02T00:00:00Z", "reason": "exception", "exception_code": 2,
      "detail": null, "attempts": 3, "raw_words": null}]}');

SELECT pg_temp.is(
  pg_temp.ingest_as('collector_sqltest_a', (SELECT batch FROM coded)) - 'first_received_at',
  '{"batch_id": "66666666-6666-4666-8666-666666666666", "resent": false,
    "readings": {"received": 1, "inserted": 1, "duplicate": 0, "conflicting": 0},
    "missed_reads": {"received": 4, "inserted": 4, "duplicate": 0},
    "firmware_reads": {"received": 0, "inserted": 0, "duplicate": 0, "conflicting": 0},
    "clock_checks": {"received": 0, "inserted": 0, "duplicate": 0, "conflicting": 0},
    "latency": {"received": 0, "inserted": 0, "duplicate": 0, "conflicting": 0}}'::jsonb,
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

-- The profile catalog: every reading and missed read names a register of a
-- loaded profile version.
CREATE FUNCTION pg_temp.renamed(batch jsonb, id text) RETURNS jsonb
LANGUAGE sql AS $$
  SELECT jsonb_set(batch, '{batch_id}', to_jsonb(id))
$$;

SELECT pg_temp.is(
  pg_temp.ingest_error('collector_sqltest_a',
    pg_temp.changed(pg_temp.renamed(:'basic', 'c0c0c0c0-c0c0-4c0c-8c0c-c0c0c0c0c0c0'),
      '{"path": ["readings", 1, "register_key"], "value": "net_energy"}')),
  'PT422: batch rejected: batch.readings[1].register_key is not a register of profile '
  || 'elite_500 version 1',
  'a reading of a register its profile version does not name is rejected, naming the field');

SELECT pg_temp.is(
  pg_temp.ingest_error('collector_sqltest_a',
    pg_temp.changed(pg_temp.renamed(:'basic', 'c0c0c0c0-c0c0-4c0c-8c0c-c0c0c0c0c0c0'),
      '{"path": ["missed_reads", 1, "register_key"], "value": "reactive_energy_import"}')),
  'PT422: batch rejected: batch.missed_reads[1].register_key is not a register of profile '
  || 'elite_440 version 1',
  'so is a missed read of one');

SELECT pg_temp.is(
  pg_temp.ingest_error('collector_sqltest_a',
    pg_temp.changed(pg_temp.renamed(:'basic', 'c0c0c0c0-c0c0-4c0c-8c0c-c0c0c0c0c0c0'),
      '{"path": ["readings", 0, "profile_version"], "value": 2}')),
  'PT503: batch.readings[0]: profile elite_440 version 2 is not loaded in the store',
  'a reading under a profile version not loaded is refused with 503, so the collector sends it again');

SELECT pg_temp.is(
  pg_temp.ingest_error('collector_sqltest_a',
    pg_temp.changed(pg_temp.renamed(:'basic', 'c0c0c0c0-c0c0-4c0c-8c0c-c0c0c0c0c0c0'),
      '{"path": ["missed_reads", 0, "profile"], "value": "elite_999"}')),
  'PT503: batch.missed_reads[0]: profile elite_999 version 1 is not loaded in the store',
  'so is a missed read under a profile not loaded');

SELECT pg_temp.is(
  (SELECT count(*) FROM store.batches WHERE batch_id = 'c0c0c0c0-c0c0-4c0c-8c0c-c0c0c0c0c0c0'),
  0::bigint,
  'and nothing of their batches is stored');

SELECT admin.load_profile(jsonb_set(:'p440', '{version}', '2'));

SELECT pg_temp.is(
  pg_temp.ingest_as('collector_sqltest_a',
    pg_temp.changed(pg_temp.renamed(:'basic', 'c0c0c0c0-c0c0-4c0c-8c0c-c0c0c0c0c0c0'),
      '{"path": ["readings", 0, "profile_version"], "value": 2}')) -> 'readings',
  '{"received": 2, "inserted": 0, "duplicate": 1, "conflicting": 1}',
  'once the version is loaded the batch is accepted, and a reading under another version of '
  || 'the stored one''s profile is conflicting');

SELECT pg_temp.is(
  (SELECT format('%s %s', profile, profile_version) FROM store.reading_conflicts
   WHERE batch_id = 'c0c0c0c0-c0c0-4c0c-8c0c-c0c0c0c0c0c0'),
  'elite_440 2',
  'the conflicting reading keeps its profile version');

SELECT pg_temp.ingest_as('collector_sqltest_a',
  pg_temp.changed(pg_temp.changed(pg_temp.renamed(:'basic', 'c1c1c1c1-c1c1-4c1c-8c1c-c1c1c1c1c1c1'),
    '{"path": ["readings"], "value": []}'),
    '{"path": ["missed_reads"], "value": [
       {"endpoint": {"host": "10.0.0.50", "port": 502}, "unit_id": 1, "meter_serial": "SIM-445-0050",
        "profile": "elite_440", "profile_version": 2, "register_key": "active_energy_export",
        "timestamp": "2026-11-03T00:00:00Z", "reason": "profile_mismatch", "exception_code": null,
        "detail": "product code ELITE440-447", "attempts": 1, "raw_words": null},
       {"endpoint": {"host": "10.0.0.50", "port": 502}, "unit_id": 2, "meter_serial": "SIM-445-0051",
        "profile": "elite_440", "profile_version": 1, "register_key": "active_energy_import",
        "timestamp": "2026-11-03T00:00:00Z", "reason": "decode", "exception_code": null,
        "detail": "NaN", "attempts": 1, "raw_words": [1, 32704]}]}'));

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s %s %s', reason, profile, profile_version,
                            coalesce(raw_words::text, 'NULL')), '; ' ORDER BY unit_id)
   FROM store.missed_reads WHERE batch_id = 'c1c1c1c1-c1c1-4c1c-8c1c-c1c1c1c1c1c1'),
  'profile_mismatch elite_440 2 NULL; decode elite_440 1 {1,32704}',
  'missed reads keep their profile version, a profile mismatch included, and the raw words '
  || 'no value came of');

-- The extremes of a float's shortest decimal: the largest finite f64, in full,
-- has 309 integer digits; the smallest subnormal, 324 fractional digits.
CREATE TEMP TABLE extremes (value text, at text);
INSERT INTO extremes VALUES
  ('17976931348623157' || repeat('0', 292), '2026-11-04T00:00:00Z'),
  ('-0.' || repeat('0', 323) || '5', '2026-11-04T00:00:01Z');

SELECT pg_temp.ingest_as('collector_sqltest_a',
  pg_temp.changed(pg_temp.renamed(:'basic', 'c2c2c2c2-c2c2-4c2c-8c2c-c2c2c2c2c2c2'),
    jsonb_build_object('path', jsonb_build_array('readings'), 'value',
      (SELECT jsonb_agg(jsonb_set(jsonb_set(:'basic'::jsonb -> 'readings' -> 1,
                                            '{value}', to_jsonb(e.value)),
                                  '{timestamp}', to_jsonb(e.at)) ORDER BY e.at)
       FROM extremes e))));

SELECT pg_temp.is(
  (SELECT string_agg(r.value::text, ' ' ORDER BY r.read_at) FROM store.readings r
   WHERE r.batch_id = 'c2c2c2c2-c2c2-4c2c-8c2c-c2c2c2c2c2c2'),
  (SELECT string_agg(e.value, ' ' ORDER BY e.at) FROM extremes e),
  'a value of 309 integer digits and one of 324 fractional digits are stored exactly');

SELECT pg_temp.is(
  pg_temp.sqlstate_as('postgres', $$
    INSERT INTO store.readings
      (meter_serial, register_key, read_at, value, profile, profile_version, endpoint_host,
       endpoint_port, unit_id, product_code, collector_id, batch_id)
    SELECT meter_serial, 'net_energy', read_at, value, profile, profile_version, endpoint_host,
           endpoint_port, unit_id, product_code, collector_id, batch_id
    FROM store.readings LIMIT 1$$),
  '23503',
  'the store refuses a reading row whose register its profile version does not name');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s.%s', table_name, column_name), ', '
                     ORDER BY table_name, column_name)
   FROM information_schema.columns
   WHERE table_schema = 'store' AND table_name IN ('readings', 'reading_conflicts', 'missed_reads')
     AND column_name IN ('raw_words', 'unit', 'kind', 'profile_version')),
  'missed_reads.profile_version, missed_reads.raw_words, reading_conflicts.profile_version, '
  || 'readings.profile_version',
  'readings carry a profile version and no raw words, unit or kind; missed reads keep raw words');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s.%s %s', table_name, column_name, data_type), '; '
                     ORDER BY table_name)
   FROM information_schema.columns
   JOIN information_schema.tables USING (table_schema, table_name)
   WHERE table_schema = 'store' AND column_name = 'value' AND table_type = 'BASE TABLE'),
  'reading_conflicts.value numeric; readings.value numeric',
  'values are stored as numeric, never float');

-- Clock checks: an answer (server times at nanoseconds), a kiss-o'-death from
-- an IPv6 address, and a timeout stamped at +05:30.
CREATE TEMP TABLE clocked (batch jsonb);
INSERT INTO clocked SELECT pg_temp.changed(pg_temp.renamed(:'basic', 'c3c3c3c3-c3c3-4c3c-8c3c-c3c3c3c3c3c3'),
  '{"path": ["clock_checks"], "value": [
     {"trigger": "daily", "server": "pool.ntp.org", "outcome": "answered",
      "t1": "2026-11-01T00:00:04.000123Z", "t2": "2026-11-01T00:00:08.215003051Z",
      "t3": "2026-11-01T00:00:08.215047312Z", "t4": "2026-11-01T00:00:04.031877Z",
      "address": "192.0.2.123", "stratum": 2, "leap": 0, "reference_id": 3221226115},
     {"trigger": "step", "server": "ntp.example.invalid", "outcome": "kiss_of_death",
      "t1": "2026-11-01T06:00:00.5Z", "t4": "2026-11-01T06:00:00.530112Z",
      "address": "2001:DB8::7B", "reference_id": 1380013125},
     {"trigger": "start", "server": "pool.ntp.org", "outcome": "timeout",
      "t1": "2026-11-02T00:00:04.000123+05:30", "t4": "2026-11-02T00:00:09+05:30"}]}');

SELECT pg_temp.is(
  pg_temp.ingest_as('collector_sqltest_a', (SELECT batch FROM clocked)) -> 'clock_checks',
  '{"received": 3, "inserted": 3, "duplicate": 0, "conflicting": 0}',
  'a batch''s clock checks are stored, and the answer counts them');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s %s %s %s %s %s %s %s %s %s %s', collector_id, trigger, server,
                            outcome, t1, t4, coalesce(t2_unix::text, '-'),
                            coalesce(t3_unix::text, '-'), coalesce(host(address), '-'),
                            coalesce(stratum::text, '-'), coalesce(leap::text, '-'),
                            coalesce(reference_id::text, '-')), '; ' ORDER BY t1)
   FROM store.clock_checks),
  'sqltest_a daily pool.ntp.org answered 2026-11-01 00:00:04.000123+00 2026-11-01 00:00:04.031877+00 '
  || '1793491208.215003051 1793491208.215047312 192.0.2.123 2 0 3221226115; '
  || 'sqltest_a step ntp.example.invalid kiss_of_death 2026-11-01 06:00:00.5+00 '
  || '2026-11-01 06:00:00.530112+00 - - 2001:db8::7b - - 1380013125; '
  || 'sqltest_a start pool.ntp.org timeout 2026-11-01 18:30:04.000123+00 2026-11-01 18:30:09+00 '
  || '- - - - - -',
  'clock checks keep the collector''s times to the microsecond, the server''s to the nanosecond '
  || 'as Unix time, and only the fields their outcome carries');

SELECT pg_temp.is(
  pg_temp.ingest_as('collector_sqltest_a', (SELECT batch FROM clocked)) -> 'clock_checks',
  '{"received": 3, "inserted": 0, "duplicate": 3, "conflicting": 0}',
  'a resent batch''s clock checks are not stored twice');

SELECT pg_temp.is(
  pg_temp.ingest_as('collector_sqltest_a',
    pg_temp.renamed((SELECT batch FROM clocked), 'c4c4c4c4-c4c4-4c4c-8c4c-c4c4c4c4c4c4'))
    -> 'clock_checks',
  '{"received": 3, "inserted": 0, "duplicate": 3, "conflicting": 0}',
  'a clock check already stored is not stored again from another batch: the key is its '
  || 'collector and t1');

SELECT pg_temp.is(
  pg_temp.ingest_as('collector_sqltest_a',
    pg_temp.changed(pg_temp.renamed((SELECT batch FROM clocked), 'c5c5c5c5-c5c5-4c5c-8c5c-c5c5c5c5c5c5'),
      '{"path": ["clock_checks", 0, "t2"], "value": "2026-11-01T00:00:08.215003052Z"}'))
    -> 'clock_checks',
  '{"received": 3, "inserted": 0, "duplicate": 2, "conflicting": 1}',
  'a clock check that differs from the stored one at its t1, by a nanosecond, is conflicting');

SELECT pg_temp.is(
  (SELECT t2_unix::text FROM store.clock_checks WHERE outcome = 'answered'),
  '1793491208.215003051',
  'and the stored clock check is unchanged');

SELECT pg_temp.is(
  pg_temp.ingest_as('collector_sqltest_b',
    pg_temp.renamed((SELECT batch FROM clocked), 'c6c6c6c6-c6c6-4c6c-8c6c-c6c6c6c6c6c6'))
    -> 'clock_checks',
  '{"received": 3, "inserted": 3, "duplicate": 0, "conflicting": 0}',
  'the same t1 from another collector is another clock check');

SELECT pg_temp.is(
  pg_temp.ingest_error('collector_sqltest_a',
    pg_temp.changed(pg_temp.renamed((SELECT batch FROM clocked), 'c7c7c7c7-c7c7-4c7c-8c7c-c7c7c7c7c7c7'),
      '{"path": ["clock_checks", 0, "t3"], "value": "2026-11-01T00:00:08.2150473120Z"}')),
  'PT422: batch rejected: batch.clock_checks[0].t3 must be a date-time to at most nanoseconds',
  'a clock check with a malformed time is rejected, naming the field');

SELECT pg_temp.is(
  pg_temp.ingest_error('collector_sqltest_a',
    pg_temp.changed(pg_temp.renamed((SELECT batch FROM clocked), 'c7c7c7c7-c7c7-4c7c-8c7c-c7c7c7c7c7c7'),
      '{"path": ["clock_checks", 2, "stratum"], "value": 2}')),
  'PT422: batch rejected: batch.clock_checks[2] has unknown field(s) stratum',
  'a timed-out clock check with a server field is rejected');

SELECT pg_temp.is(pg_temp.sqlstate_as('postgres', q), '23514', 'the store refuses: ' || q)
FROM unnest(ARRAY[
  $q$INSERT INTO store.clock_checks (collector_id, t1, t4, trigger, server, outcome, stratum, batch_id)
     SELECT collector_id, t1 + interval '1 day', t4, trigger, server, 'timeout', 2, batch_id
     FROM store.clock_checks LIMIT 1$q$,
  $q$INSERT INTO store.clock_checks (collector_id, t1, t4, trigger, server, outcome, batch_id)
     SELECT collector_id, t1 + interval '1 day', t4, trigger, server, 'answered', batch_id
     FROM store.clock_checks LIMIT 1$q$,
  $q$INSERT INTO store.clock_checks (collector_id, t1, t4, trigger, server, outcome, address, reference_id, t2_unix, batch_id)
     SELECT collector_id, t1 + interval '1 day', t4, trigger, server, 'kiss_of_death', address, 1, 1, batch_id
     FROM store.clock_checks LIMIT 1$q$,
  $q$INSERT INTO store.clock_checks
     SELECT collector_id, t1 + interval '1 day', t4, trigger, server, outcome, t2_unix + 0.0000000001,
            t3_unix, address, stratum, leap, reference_id, batch_id
     FROM store.clock_checks WHERE outcome = 'answered' LIMIT 1$q$
]) q;

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
  'TRUNCATE store.firmware_reads',
  $q$UPDATE store.clock_checks SET server = 'x'$q$,
  'DELETE FROM store.clock_checks',
  'TRUNCATE store.clock_checks'
]) q;

ROLLBACK;
