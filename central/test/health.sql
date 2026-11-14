-- The health views: what they report per collector and per meter, and which
-- problems they flag, judged by the thresholds in registry.health_thresholds.
-- Uploads and readings are inserted directly, with times relative to now(),
-- since api.ingest stamps everything with the time of the call.

\ir lib/assert.sql

BEGIN;

SELECT admin.set_health_thresholds(collector_silent_after => '1 hour',
  meter_silent_intervals => 4, backlog_near_capacity => 0.8, lookback => '1 day');

SELECT admin.create_collector(c) FROM unnest(ARRAY['sqlh_a', 'sqlh_b', 'sqlh_c', 'sqlh_d']) c;

-- A batch received `ago`, with its upload and the backlog it reported
-- (capacity 1000 bytes).
CREATE FUNCTION pg_temp.upload(collector text, ago interval, bytes bigint, refused bigint,
                               discarded bigint, quarantined bigint)
RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  id uuid := gen_random_uuid();
BEGIN
  INSERT INTO store.batches VALUES (id, collector, now() - ago, 'ntp', now() - ago - interval '1 minute', 0, 0);
  INSERT INTO store.uploads
    (batch_id, collector_id, received_at, sent_at, backlog_events, backlog_bytes, backlog_batches,
     backlog_oldest, backlog_max_bytes, backlog_refused, backlog_discarded_files,
     backlog_quarantined, readings_inserted, readings_duplicate, readings_conflicting,
     missed_reads_inserted, missed_reads_duplicate)
  VALUES (id, collector, now() - ago, now() - ago, 10, bytes, 1, now() - ago, 1000, refused,
          discarded, quarantined, 0, 0, 0, 0, 0);
  RETURN id;
END
$$;

-- Readings and missed reads at 10.0.0.1:502, from the batch's collector.
CREATE FUNCTION pg_temp.reading(serial text, batch uuid, ago interval, unit integer) RETURNS void
LANGUAGE sql AS $$
  INSERT INTO store.readings
  SELECT serial, 'active_energy_import', now() - ago, 1.0, 'Wh', '{0,0}', 'elite_440', '10.0.0.1',
         502, unit, b.collector_id, batch, 'ELITE440-445'
  FROM store.batches b WHERE b.batch_id = batch
$$;

CREATE FUNCTION pg_temp.missed(serial text, batch uuid, ago interval, reason store.missed_reason,
                               unit integer)
RETURNS void
LANGUAGE sql AS $$
  INSERT INTO store.missed_reads
  SELECT serial, 'active_energy_import', now() - ago, reason, NULL, NULL, 3, NULL, 'elite_440',
         '10.0.0.1', 502, unit, b.collector_id, batch
  FROM store.batches b WHERE b.batch_id = batch
$$;

CREATE FUNCTION pg_temp.endpoint(id text, collector text, host text, other boolean) RETURNS bigint
LANGUAGE sql AS $$
  SELECT admin.register_endpoint(
    endpoint_id => id, valid_from => now() - interval '2 days', collector_id => collector,
    host => host, port => 502, framing => 'tcp', polled_by_other_system => other,
    timeout_ms => 1000, max_timeouts => 3, retries => 2, busy_backoff_ms => 500,
    reconnect_backoff_min_ms => 1000, reconnect_backoff_max_ms => 60000, interval_ms => 900000)
$$;

CREATE FUNCTION pg_temp.meter(serial text, endpoint text, unit integer, ago interval,
                              interval_ms integer)
RETURNS bigint
LANGUAGE sql AS $$
  SELECT admin.register_meter(serial => serial, valid_from => now() - ago, endpoint_id => endpoint,
    unit_id => unit, profile => 'elite_440', interval_ms => interval_ms)
$$;

SELECT pg_temp.endpoint('sqlh_a_ep', 'sqlh_a', '10.0.0.1', false);
SELECT pg_temp.endpoint('sqlh_a_other', 'sqlh_a', '10.0.0.99', true);
SELECT pg_temp.endpoint('sqlh_b_ep', 'sqlh_b', '10.0.0.1', false);
SELECT pg_temp.endpoint('sqlh_d_ep', 'sqlh_d', '10.0.0.1', false);

-- Meters every 15 minutes (the endpoint's) unless said otherwise; silent after 1 hour.
SELECT pg_temp.meter('SQLH-0001', 'sqlh_a_ep', 1, '2 days', NULL);      -- read 5 minutes ago
SELECT pg_temp.meter('SQLH-0002', 'sqlh_a_ep', 2, '2 days', NULL);      -- read 2 hours ago
SELECT pg_temp.meter('SQLH-0003', 'sqlh_a_ep', 3, '2 days', 86400000);  -- daily, read 2 hours ago
SELECT pg_temp.meter('SQLH-0004', 'sqlh_a_ep', 4, '2 days', NULL);      -- retired, never read
SELECT admin.retire_meter('SQLH-0004', now() - interval '1 day');
SELECT pg_temp.meter('SQLH-0005', 'sqlh_a_ep', 5, '10 minutes', NULL);  -- new, not read yet
SELECT pg_temp.meter('SQLH-0008', 'sqlh_a_ep', 8, '2 days', NULL);      -- back in service 30 min ago
SELECT admin.retire_meter('SQLH-0008', now() - interval '1 day');
SELECT admin.change_meter('SQLH-0008', now() - interval '30 minutes', 'sqlh_a_ep', 8, 'elite_440', NULL);
SELECT pg_temp.meter('SQLH-0006', 'sqlh_a_other', 1, '2 days', NULL);   -- polled by the other system
SELECT pg_temp.meter('SQLH-0007', 'sqlh_b_ep', 1, '2 days', NULL);      -- behind a silent collector

CREATE TEMP TABLE b (collector text PRIMARY KEY, batch uuid);
INSERT INTO b VALUES
  ('sqlh_a', pg_temp.upload('sqlh_a', '5 minutes', 850, 0, 0, 2)),
  ('sqlh_b', pg_temp.upload('sqlh_b', '2 hours', 0, 0, 0, 0)),
  -- no endpoint in service: not judged, whatever it reports
  ('sqlh_c', pg_temp.upload('sqlh_c', '3 hours', 990, 4, 4, 4)),
  ('sqlh_d', pg_temp.upload('sqlh_d', '1 minute', 100, 7, 1, 0));

SELECT pg_temp.reading('SQLH-0001', (SELECT batch FROM b WHERE collector = 'sqlh_a'), '5 minutes', 1);
SELECT pg_temp.reading('SQLH-0002', (SELECT batch FROM b WHERE collector = 'sqlh_a'), '2 hours', 2);
SELECT pg_temp.reading('SQLH-0003', (SELECT batch FROM b WHERE collector = 'sqlh_a'), '2 hours', 3);
SELECT pg_temp.reading('SQLH-0008', (SELECT batch FROM b WHERE collector = 'sqlh_a'), '47 hours', 8);
SELECT pg_temp.reading('SQLH-STRAY', (SELECT batch FROM b WHERE collector = 'sqlh_a'), '1 hour', 9);
SELECT pg_temp.reading('SQLH-OLD-STRAY', (SELECT batch FROM b WHERE collector = 'sqlh_a'), '3 days', 9);
-- SQLH-0002 at its own unit; one with no serial read at its address; one
-- at its address whose serial read was another meter's.
SELECT pg_temp.missed(s, (SELECT batch FROM b WHERE collector = 'sqlh_a'), i, r, 2)
FROM (VALUES ('SQLH-0002', '10 minutes'::interval, 'timeout'::store.missed_reason),
             ('SQLH-0002', '20 minutes', 'timeout'), (NULL, '30 minutes', 'exception'),
             ('SQLH-0001', '40 minutes', 'exception'), ('SQLH-0002', '2 days', 'timeout')) v (s, i, r);
-- With no serial read, at an address with no meter registered: no meter's.
SELECT pg_temp.missed(NULL, (SELECT batch FROM b WHERE collector = 'sqlh_a'), '10 minutes',
                      'timeout', 9);

-- SQLH-0003 read at unit 7 of its own endpoint; SQLH-0007 read through
-- sqlh_d at the host and port its endpoint has under sqlh_b; SQLH-0005 read
-- at unit 9 before it was registered, which is not judged.
SELECT pg_temp.reading('SQLH-0003', (SELECT batch FROM b WHERE collector = 'sqlh_a'), '3 hours', 7);
SELECT pg_temp.reading('SQLH-0003', (SELECT batch FROM b WHERE collector = 'sqlh_a'), '4 hours', 7);
SELECT pg_temp.reading('SQLH-0007', (SELECT batch FROM b WHERE collector = 'sqlh_d'), '5 hours', 1);
SELECT pg_temp.reading('SQLH-0005', (SELECT batch FROM b WHERE collector = 'sqlh_a'), '1 hour', 9);
-- SQLH-TWIN, not registered, read at unit 10 through both sqlh_a and sqlh_d;
-- SQLH-STRAY read at unit 11 too, outside the lookback.
SELECT pg_temp.reading('SQLH-TWIN', (SELECT batch FROM b WHERE collector = 'sqlh_a'), '30 minutes', 10);
SELECT pg_temp.reading('SQLH-TWIN', (SELECT batch FROM b WHERE collector = 'sqlh_a'), '40 minutes', 10);
SELECT pg_temp.reading('SQLH-TWIN', (SELECT batch FROM b WHERE collector = 'sqlh_d'), '20 minutes', 10);
SELECT pg_temp.reading('SQLH-STRAY', (SELECT batch FROM b WHERE collector = 'sqlh_a'), '3 days', 11);

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s', kind, subject), '; ' ORDER BY kind, subject)
   FROM health.problems),
  'backlog_discarded sqlh_d; backlog_near_capacity sqlh_a; backlog_quarantined sqlh_a; '
  || 'backlog_refused sqlh_d; collector_silent sqlh_b; meter_silent SQLH-0002; '
  || 'misplaced_serial SQLH-0003; misplaced_serial SQLH-0007; '
  || 'serial_at_several_places SQLH-TWIN; unregistered_serial SQLH-STRAY; '
  || 'unregistered_serial SQLH-TWIN',
  'exactly the problems there are are flagged');

SELECT pg_temp.is(
  (SELECT detail FROM health.problems WHERE kind = 'meter_silent'),
  format('no reading since %s (expected every 00:15:00), on sqlh_a_ep unit 2, collector sqlh_a',
         now() - interval '2 hours'),
  'a silent meter''s problem says since when, how often it is due, and where it is');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s', serial, silent), ', ' ORDER BY serial) FROM health.meters
   WHERE serial LIKE 'SQLH-%'),
  'SQLH-0001 f, SQLH-0002 t, SQLH-0003 f, SQLH-0004 f, SQLH-0005 f, '
  || 'SQLH-0006 f, SQLH-0007 t, SQLH-0008 f',
  'a meter is silent after its own interval times the threshold, not when retired, new, '
  || 'just back in service or polled by another system');

SELECT pg_temp.is(
  (SELECT format('%s %s %s %s', last_reading_at = now() - interval '2 hours', missed_reads,
                 missed_by_reason, expected_interval)
   FROM health.meters WHERE serial = 'SQLH-0002'),
  't 3 {"timeout": 2, "exception": 1} 00:15:00',
  'a meter shows its last reading and its missed reads within the lookback, by reason, '
  || 'counting those at its address with no serial read');

SELECT pg_temp.is(
  (SELECT format('%s %s', missed_reads, missed_by_reason) FROM health.meters
   WHERE serial = 'SQLH-0001'),
  '1 {"exception": 1}',
  'a missed read counts for the meter whose serial was read on it, wherever it was');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s %s:%s %s %s %s %s', serial, collector_id, endpoint_host,
                            endpoint_port, unit_id, readings,
                            last_reading_at = now() - interval '3 hours', registered_at),
                     '; ' ORDER BY serial)
   FROM health.misplaced_serials),
  'SQLH-0003 sqlh_a 10.0.0.1:502 7 2 t {"sqlh_a_ep unit 3"}; '
  || 'SQLH-0007 sqlh_d 10.0.0.1:502 1 1 f {"sqlh_b_ep unit 1"}',
  'a registered serial read where the registry did not place it is listed, per place read');

SELECT pg_temp.is(
  (SELECT detail FROM health.problems WHERE kind = 'misplaced_serial' AND subject = 'SQLH-0007'),
  format('1 readings, the last at %s, at 10.0.0.1:502 unit 1 via sqlh_d (registered at sqlh_b_ep unit 1)',
         now() - interval '5 hours'),
  'a misplaced serial''s problem says where it was read and where it is registered');

SELECT admin.change_meter('SQLH-0003', now() - interval '5 hours', 'sqlh_a_ep', 7, 'elite_440',
                          86400000);

SELECT pg_temp.is(
  (SELECT string_agg(serial, ', ' ORDER BY serial) FROM health.misplaced_serials),
  'SQLH-0003, SQLH-0007',
  'readings are judged by where the registry placed the meter when each was taken');

SELECT pg_temp.is(
  (SELECT format('%s %s', readings, registered_at) FROM health.misplaced_serials
   WHERE serial = 'SQLH-0003'),
  '1 {"sqlh_a_ep unit 7"}',
  'after a move recorded from before them, only the readings at the old place are misplaced');

SELECT pg_temp.is(
  (SELECT format('%s %s %s %s %s %s %s %s', in_service, endpoints,
                 last_upload_at = now() - interval '5 minutes',
                 last_reading_at = now() - interval '5 minutes', clock_source, backlog_used,
                 missed_reads, missed_by_reason)
   FROM health.collectors WHERE collector_id = 'sqlh_a'),
  't 2 t t ntp 0.8500 5 {"timeout": 3, "exception": 2}',
  'a collector shows its last upload and reading, clock, backlog and missed reads');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s %s', collector_id, in_service, silent), ', '
                     ORDER BY collector_id)
   FROM health.collectors WHERE collector_id LIKE 'sqlh_%'),
  'sqlh_a t f, sqlh_b t t, sqlh_c f f, sqlh_d t f',
  'a collector is judged only while it has an endpoint in service');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s', serial, readings), ', ' ORDER BY serial)
   FROM health.unregistered_serials),
  'SQLH-STRAY 1, SQLH-TWIN 3',
  'only serials read within the lookback are listed as unregistered');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s %s:%s %s %s', serial, collector_id, endpoint_host,
                            endpoint_port, unit_id, readings),
                     '; ' ORDER BY serial, collector_id)
   FROM health.unregistered_serial_places),
  'SQLH-STRAY sqlh_a 10.0.0.1:502 9 1; SQLH-TWIN sqlh_a 10.0.0.1:502 10 2; '
  || 'SQLH-TWIN sqlh_d 10.0.0.1:502 10 1',
  'an unregistered serial is listed per place read within the lookback');

SELECT pg_temp.is(
  (SELECT detail FROM health.problems
   WHERE kind = 'serial_at_several_places' AND subject = 'SQLH-TWIN'),
  format('2 readings, the last at %s, at 10.0.0.1:502 unit 10 via sqlh_a; '
         || '1 readings, the last at %s, at 10.0.0.1:502 unit 10 via sqlh_d',
         now() - interval '30 minutes', now() - interval '20 minutes'),
  'an unregistered serial read at several places says each place and when it was read there');

-- Firmware reads at 10.0.0.1:502, from the batch's collector, with the
-- software and module 1 names given (module 2 and the version fixed).
CREATE FUNCTION pg_temp.firmware(serial text, batch uuid, ago interval, software text,
                                 firmware_1 text, unit integer)
RETURNS void
LANGUAGE sql AS $$
  INSERT INTO store.firmware_reads
  SELECT serial, 'ELITE440-445', now() - ago, software, firmware_1, 'SIM-F2', '0B03', '10.0.0.1',
         502, unit, b.collector_id, batch
  FROM store.batches b WHERE b.batch_id = batch
$$;

INSERT INTO b VALUES ('sqlh_c_old', pg_temp.upload('sqlh_c', '2 days', 0, 0, 0, 0));

-- SQLF-0001 upgraded; SQLF-0002 sent the same names again after a restart;
-- SQLF-0003 has one record; SQLF-0004 changed in a batch that arrived two
-- days ago; SQLF-0005 stopped giving its module 1 name; SQLF-0006 changed and
-- then sent the new names again; SQLF-0007 changed ten days ago, in a batch
-- that arrived five minutes ago.
SELECT pg_temp.firmware(s, (SELECT batch FROM b WHERE collector = c), i, sw, f1,
                        20 + right(s, 1)::integer)
FROM (VALUES ('SQLF-0001', 'sqlh_a', '3 days'::interval, 'SIM-SW1', 'SIM-F1'),
             ('SQLF-0001', 'sqlh_a', '10 minutes', 'SIM-SW2', 'SIM-F1'),
             ('SQLF-0002', 'sqlh_a', '3 days', 'SIM-SW1', 'SIM-F1'),
             ('SQLF-0002', 'sqlh_a', '10 minutes', 'SIM-SW1', 'SIM-F1'),
             ('SQLF-0003', 'sqlh_a', '10 minutes', 'SIM-SW1', 'SIM-F1'),
             ('SQLF-0004', 'sqlh_c_old', '3 days', 'SIM-SW1', 'SIM-F1'),
             ('SQLF-0004', 'sqlh_c_old', '2 days', 'SIM-SW2', 'SIM-F1'),
             ('SQLF-0005', 'sqlh_a', '3 days', 'SIM-SW1', 'SIM-F1'),
             ('SQLF-0005', 'sqlh_a', '10 minutes', 'SIM-SW1', NULL),
             ('SQLF-0006', 'sqlh_a', '3 days', 'SIM-SW1', 'SIM-F1'),
             ('SQLF-0006', 'sqlh_a', '2 days', 'SIM-SW2', 'SIM-F1'),
             ('SQLF-0006', 'sqlh_a', '10 minutes', 'SIM-SW2', 'SIM-F1'),
             ('SQLF-0007', 'sqlh_a', '11 days', 'SIM-SW1', 'SIM-F1'),
             ('SQLF-0007', 'sqlh_a', '10 days', 'SIM-SW2', 'SIM-F1')) v (s, c, i, sw, f1);

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s %s %s', serial, software, coalesce(firmware_1, 'NULL'),
                            changed), ', ' ORDER BY serial)
   FROM health.meter_firmware WHERE serial LIKE 'SQLF-%'),
  'SQLF-0001 SIM-SW2 SIM-F1 t, SQLF-0002 SIM-SW1 SIM-F1 f, SQLF-0003 SIM-SW1 SIM-F1 f, '
  || 'SQLF-0004 SIM-SW2 SIM-F1 t, SQLF-0005 SIM-SW1 NULL t, SQLF-0006 SIM-SW2 SIM-F1 f, '
  || 'SQLF-0007 SIM-SW2 SIM-F1 t',
  'each serial''s latest names are shown, and whether they differ from the record before them');

SELECT pg_temp.is(
  (SELECT string_agg(subject, ', ' ORDER BY subject) FROM health.problems
   WHERE kind = 'firmware_changed'),
  'SQLF-0001, SQLF-0005, SQLF-0007',
  'a firmware change is flagged while the record showing it arrived within the lookback, '
  || 'and unchanged names are not');

SELECT pg_temp.is(
  (SELECT detail FROM health.problems WHERE kind = 'firmware_changed' AND subject = 'SQLF-0005'),
  format('software SIM-SW1, firmware SIM-F1 / SIM-F2, modbus 0B03 (read %s) became '
         || 'software SIM-SW1, firmware (none) / SIM-F2, modbus 0B03 (read %s), '
         || 'at 10.0.0.1:502 unit 25 via sqlh_a',
         now() - interval '3 days', now() - interval '10 minutes'),
  'a firmware change''s problem says the names before and after, when each was read, and where');

SELECT admin.set_health_thresholds(collector_silent_after => '3 hours',
  meter_silent_intervals => 10, backlog_near_capacity => 0.9, lookback => '4 days');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s', kind, subject), '; ' ORDER BY kind, subject)
   FROM health.problems WHERE kind IN ('collector_silent', 'meter_silent', 'backlog_near_capacity',
                                       'unregistered_serial', 'serial_at_several_places')),
  'meter_silent SQLH-0007; serial_at_several_places SQLH-STRAY; '
  || 'serial_at_several_places SQLH-TWIN; unregistered_serial SQLH-OLD-STRAY; '
  || 'unregistered_serial SQLH-STRAY; unregistered_serial SQLH-TWIN',
  'the latest thresholds set are the ones judged by');

SELECT pg_temp.is(
  (SELECT string_agg(subject, ', ' ORDER BY subject) FROM health.problems
   WHERE kind = 'firmware_changed'),
  'SQLF-0001, SQLF-0004, SQLF-0005, SQLF-0007',
  'a firmware change is judged by the lookback in force');

SELECT pg_temp.is(
  (SELECT format('%s %s %s %s', collector_silent_after, meter_silent_intervals,
                 backlog_near_capacity, lookback)
   FROM health.thresholds),
  '03:00:00 10 0.9 4 days',
  'health.thresholds shows the thresholds in force');

ROLLBACK;
