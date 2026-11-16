-- The health views: what they report per collector and per meter, and which
-- problems they flag, judged by the thresholds in registry.health_thresholds.
-- Uploads and readings are inserted directly, with times relative to now(),
-- since api.ingest stamps everything with the time of the call.

\ir lib/assert.sql

BEGIN;

SELECT admin.set_health_thresholds(collector_silent_after => '1 hour',
  meter_silent_intervals => 4, backlog_near_capacity => 0.8, lookback => '1 day',
  endpoint_error_rate => 0.05, snapshot_missed_margin => '1 hour',
  history_behind_after => '62 days', snapshot_behind_after_elite_500 => '14 days',
  load_survey_behind_after_elite_440 => '7 days', load_survey_behind_after_elite_500 => '30 days');

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
     missed_reads_inserted, missed_reads_duplicate, stored_entries_inserted,
     stored_entries_duplicate, stored_entries_conflicting, meter_clock_reads_inserted,
     meter_clock_reads_duplicate, meter_clock_reads_conflicting)
  VALUES (id, collector, now() - ago, now() - ago, 10, bytes, 1, now() - ago, 1000, refused,
          discarded, quarantined, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
  RETURN id;
END
$$;

-- Readings and missed reads at 10.0.0.1:502, from the batch's collector.
CREATE FUNCTION pg_temp.reading(serial text, batch uuid, ago interval, unit integer) RETURNS void
LANGUAGE sql AS $$
  INSERT INTO store.readings
  SELECT serial, 'active_energy_import', now() - ago, 1.0, 'elite_440', '10.0.0.1', 502, unit,
         b.collector_id, batch, 'ELITE440-445', 2
  FROM store.batches b WHERE b.batch_id = batch
$$;

CREATE FUNCTION pg_temp.missed(serial text, batch uuid, ago interval, reason store.missed_reason,
                               unit integer)
RETURNS void
LANGUAGE sql AS $$
  INSERT INTO store.missed_reads
  SELECT serial, 'active_energy_import', now() - ago, reason, NULL, NULL, 3, NULL, 'elite_440',
         '10.0.0.1', 502, unit, b.collector_id, batch, 2
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

CREATE FUNCTION pg_temp.target(endpoint text, unit integer, ago interval, interval_ms integer)
RETURNS bigint
LANGUAGE sql AS $$
  SELECT admin.register_target(endpoint_id => endpoint, unit_id => unit, valid_from => now() - ago,
    profile => 'elite_440', interval_ms => interval_ms)
$$;

-- A meter at a target of its own, registered with it.
CREATE FUNCTION pg_temp.meter(serial text, endpoint text, unit integer, ago interval,
                              interval_ms integer)
RETURNS bigint
LANGUAGE sql AS $$
  SELECT pg_temp.target(endpoint, unit, ago, interval_ms);
  SELECT admin.register_meter(serial => serial, valid_from => now() - ago, endpoint_id => endpoint,
    unit_id => unit)
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
SELECT admin.retire_target('sqlh_a_ep', 4, now() - interval '1 day');
SELECT pg_temp.meter('SQLH-0005', 'sqlh_a_ep', 5, '10 minutes', NULL);  -- new, not read yet
SELECT pg_temp.meter('SQLH-0008', 'sqlh_a_ep', 8, '2 days', NULL);      -- back in service 30 min ago
SELECT admin.retire_meter('SQLH-0008', now() - interval '1 day');
SELECT admin.retire_target('sqlh_a_ep', 8, now() - interval '1 day');
SELECT admin.change_target('sqlh_a_ep', 8, now() - interval '30 minutes', 'elite_440', NULL);
SELECT admin.change_meter('SQLH-0008', now() - interval '30 minutes', 'sqlh_a_ep', 8);
SELECT pg_temp.meter('SQLH-0006', 'sqlh_a_other', 1, '2 days', NULL);   -- polled by the other system
SELECT pg_temp.meter('SQLH-0007', 'sqlh_b_ep', 1, '2 days', NULL);      -- behind a silent collector

-- Targets judged whatever serial answers, on sqlh_d's endpoint: unit 13 never
-- read; unit 10 read with an unregistered serial (SQLH-TWIN, below); unit 14
-- with a missed read only; unit 15 holds a meter never read. sqlh_m_ep moved
-- from 10.0.0.2 to 10.0.0.3 30 minutes ago: its unit 1, holding SQLT-0002,
-- had a reading and a missed read at the old address before the move, its
-- unit 2 a missed read only after it.
SELECT pg_temp.target('sqlh_d_ep', u, '2 days', NULL) FROM unnest(ARRAY[10, 13, 14]) u;
SELECT pg_temp.meter('SQLT-0001', 'sqlh_d_ep', 15, '2 days', NULL);
SELECT pg_temp.endpoint('sqlh_m_ep', 'sqlh_d', '10.0.0.2', false);
SELECT admin.change_endpoint(endpoint_id => 'sqlh_m_ep', valid_from => now() - interval '30 minutes',
  collector_id => 'sqlh_d', host => '10.0.0.3', port => 502, framing => 'tcp',
  polled_by_other_system => false, timeout_ms => 1000, max_timeouts => 3, retries => 2,
  busy_backoff_ms => 500, reconnect_backoff_min_ms => 1000, reconnect_backoff_max_ms => 60000,
  interval_ms => 900000, copy => false);
SELECT pg_temp.target('sqlh_m_ep', u, '2 days', NULL) FROM unnest(ARRAY[1, 2]) u;
SELECT admin.register_meter(serial => 'SQLT-0002', valid_from => now() - interval '2 days',
  endpoint_id => 'sqlh_m_ep', unit_id => 1);

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

SELECT pg_temp.missed(NULL, (SELECT batch FROM b WHERE collector = 'sqlh_d'), '10 minutes',
                      'decode', 14);
INSERT INTO store.missed_reads
SELECT NULL, 'active_energy_import', now() - ago, 'decode', NULL, NULL, 3, NULL, 'elite_440',
       '10.0.0.2', 502, unit, 'sqlh_d', (SELECT batch FROM b WHERE collector = 'sqlh_d'), 2
FROM (VALUES (1, '40 minutes'::interval), (2, '20 minutes')) v (unit, ago);
INSERT INTO store.readings
SELECT 'SQLT-0002', 'active_energy_import', now() - interval '50 minutes', 1.0, 'elite_440',
       '10.0.0.2', 502, 1, 'sqlh_d', (SELECT batch FROM b WHERE collector = 'sqlh_d'),
       'ELITE440-445', 2;

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
-- Unit 12 answering with two serials in turn, as two meters on one address
-- would; unit 9 already gave SQLH-STRAY and SQLH-0005 (and SQLH-OLD-STRAY,
-- outside the lookback).
SELECT pg_temp.reading(s, (SELECT batch FROM b WHERE collector = 'sqlh_a'), i, 12)
FROM (VALUES ('SQLS-A', '50 minutes'::interval), ('SQLS-B', '40 minutes'),
             ('SQLS-A', '30 minutes'), ('SQLS-B', '20 minutes'),
             ('SQLS-A', '10 minutes')) v (s, i);

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s', kind, subject), '; ' ORDER BY kind, subject)
   FROM health.problems),
  'backlog_discarded sqlh_d; backlog_near_capacity sqlh_a; backlog_quarantined sqlh_a; '
  || 'backlog_refused sqlh_d; collector_silent sqlh_b; endpoint_errors sqlh_a_ep; '
  || 'misplaced_serial SQLH-0003; misplaced_serial SQLH-0007; '
  || 'serial_at_several_places SQLH-TWIN; several_serials_at_place 10.0.0.1:502 unit 12 via sqlh_a; '
  || 'several_serials_at_place 10.0.0.1:502 unit 9 via sqlh_a; '
  || 'target_silent sqlh_a_ep unit 2; target_silent sqlh_d_ep unit 13; '
  || 'target_silent sqlh_d_ep unit 14; target_silent sqlh_d_ep unit 15; '
  || 'target_silent sqlh_m_ep unit 2; unregistered_serial SQLH-STRAY; '
  || 'unregistered_serial SQLH-TWIN; unregistered_serial SQLS-A; unregistered_serial SQLS-B',
  'exactly the problems there are are flagged');

SAVEPOINT swapped;
-- Another serial answering at SQLH-0002's unit, as an unrecorded swap would.
SELECT pg_temp.reading('SQLH-SWAPPED', (SELECT batch FROM b WHERE collector = 'sqlh_a'),
                       '5 minutes', 2);
SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s', kind, subject), '; ' ORDER BY kind, subject)
   FROM health.problems WHERE kind IN ('meter_silent', 'target_silent')
                          AND subject IN ('SQLH-0002', 'sqlh_a_ep unit 2')),
  'meter_silent SQLH-0002',
  'a silent meter at a target that answers is listed as the meter');
SELECT pg_temp.is(
  (SELECT detail FROM health.problems WHERE kind = 'meter_silent'),
  format('no reading since %s (expected every 00:15:00), on sqlh_a_ep unit 2, collector sqlh_a',
         now() - interval '2 hours'),
  'a silent meter''s problem says since when, how often it is due, and where it is');
ROLLBACK TO SAVEPOINT swapped;

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s', serial, silent), ', ' ORDER BY serial) FROM health.meters
   WHERE serial LIKE 'SQLH-%'),
  'SQLH-0001 f, SQLH-0002 t, SQLH-0003 f, SQLH-0004 f, SQLH-0005 f, '
  || 'SQLH-0006 f, SQLH-0007 t, SQLH-0008 f',
  'a meter is silent after its own interval times the threshold, not when retired, new, '
  || 'just back in service or polled by another system');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s/%s %s', endpoint_id, unit_id, silent), ', '
                     ORDER BY endpoint_id, unit_id)
   FROM health.targets WHERE endpoint_id LIKE 'sqlh_%'),
  'sqlh_a_ep/1 f, sqlh_a_ep/2 t, sqlh_a_ep/3 f, sqlh_a_ep/4 f, sqlh_a_ep/5 f, sqlh_a_ep/8 f, '
  || 'sqlh_a_other/1 f, sqlh_b_ep/1 t, sqlh_d_ep/10 f, sqlh_d_ep/13 t, sqlh_d_ep/14 t, '
  || 'sqlh_d_ep/15 t, sqlh_m_ep/1 f, sqlh_m_ep/2 t',
  'a target is silent with no reading at its unit, whatever serial and whatever missed reads, '
  || 'at any address its endpoint had then, for its interval times the threshold; not when '
  || 'retired, new, just back in service or polled by another system');

SELECT pg_temp.is(
  (SELECT format('%s %s %s %s %s %s', profile, coalesce(serial, '-'), expected_interval,
                 last_reading_at IS NULL, last_missed_read_at = now() - interval '10 minutes',
                 in_service_since = now() - interval '2 days')
   FROM health.targets WHERE endpoint_id = 'sqlh_d_ep' AND unit_id = 14),
  'elite_440 - 00:15:00 t t t',
  'a target shows its profile, the meter placed there, its interval and its last reading and '
  || 'missed read');

SELECT pg_temp.is(
  (SELECT detail FROM health.problems WHERE kind = 'target_silent'
   AND subject = 'sqlh_d_ep unit 15'),
  'no reading since it came into service (expected every 00:15:00; no missed read), '
  || 'at 10.0.0.1:502 unit 15 via sqlh_d, profile elite_440, meter SQLT-0001',
  'a silent target''s problem says since when, how often it is due, where it is and its meter');

SELECT pg_temp.is(
  (SELECT detail FROM health.problems WHERE kind = 'target_silent'
   AND subject = 'sqlh_a_ep unit 2'),
  format('no reading since %s (expected every 00:15:00; last missed read %s), '
         || 'at 10.0.0.1:502 unit 2 via sqlh_a, profile elite_440, meter SQLH-0002',
         now() - interval '2 hours', now() - interval '10 minutes'),
  'a silent target''s problem gives its last missed read, which does not keep it from silence');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s', unit_id, coalesce((now() - last_missed_read_at)::text, '-')),
                     ', ' ORDER BY unit_id)
   FROM health.targets WHERE endpoint_id = 'sqlh_m_ep'),
  '1 00:40:00, 2 -',
  'a target''s last missed read is the last at an address its endpoint had then');

SELECT pg_temp.ok(
  (SELECT silent FROM health.meters WHERE serial = 'SQLT-0001')
  AND NOT EXISTS (SELECT FROM health.problems WHERE kind = 'meter_silent'
                  AND subject = 'SQLT-0001'),
  'a silent meter at a silent target is listed as the target alone');

SELECT pg_temp.is(pg_temp.unkeyed_scans('SELECT * FROM health.targets'), NULL,
  'health.targets finds the last reading and missed read at each address by index');

-- Each index lookup on readings or missed reads in the plan of q, by table,
-- and whether the unit id is in its index condition.
CREATE FUNCTION pg_temp.unit_lookups(q text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
  plan jsonb;
BEGIN
  SET LOCAL enable_seqscan = off;
  EXECUTE 'EXPLAIN (FORMAT JSON) ' || q INTO plan;
  RESET enable_seqscan;
  RETURN (SELECT string_agg(DISTINCT format('%s %s',
                                            regexp_replace(n ->> 'Index Name',
                                                           '^(_hyper_[0-9]+_[0-9]+_chunk_)?(readings|missed_reads)_.*$',
                                                           '\2'),
                                            (n ->> 'Index Cond' ~ 'unit_id')::text), ', ')
          FROM jsonb_path_query(plan, 'lax $.**') n
          WHERE jsonb_typeof(n) = 'object'
            AND n ->> 'Index Name' ~ '^(_hyper_[0-9]+_[0-9]+_chunk_)?(readings|missed_reads)_');
END
$$;

SELECT pg_temp.is(pg_temp.unit_lookups('SELECT * FROM health.targets'),
  'missed_reads true, readings true',
  'health.targets looks readings and missed reads up by their unit''s address, not the endpoint''s');

SAVEPOINT old_address;
-- A reading at sqlh_m_ep's old address after it moved is not its unit's.
INSERT INTO store.readings
SELECT 'SQLS-A', 'active_energy_import', now() - interval '11 minutes', 1.0, 'elite_440',
       '10.0.0.2', 502, 2, 'sqlh_d', (SELECT batch FROM b WHERE collector = 'sqlh_d'),
       'ELITE440-445', 2;
SELECT pg_temp.ok(
  (SELECT silent FROM health.targets WHERE endpoint_id = 'sqlh_m_ep' AND unit_id = 2),
  'a reading at an address the endpoint no longer had does not count for its target');
ROLLBACK TO SAVEPOINT old_address;

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

SELECT pg_temp.target('sqlh_a_ep', 7, '5 hours', 86400000);
SELECT admin.change_meter('SQLH-0003', now() - interval '5 hours', 'sqlh_a_ep', 7);

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
  'SQLH-STRAY 1, SQLH-TWIN 3, SQLS-A 3, SQLS-B 2',
  'only serials read within the lookback are listed as unregistered');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s %s:%s %s %s', serial, collector_id, endpoint_host,
                            endpoint_port, unit_id, readings),
                     '; ' ORDER BY serial, collector_id)
   FROM health.unregistered_serial_places),
  'SQLH-STRAY sqlh_a 10.0.0.1:502 9 1; SQLH-TWIN sqlh_a 10.0.0.1:502 10 2; '
  || 'SQLH-TWIN sqlh_d 10.0.0.1:502 10 1; SQLS-A sqlh_a 10.0.0.1:502 12 3; '
  || 'SQLS-B sqlh_a 10.0.0.1:502 12 2',
  'an unregistered serial is listed per place read within the lookback');

SELECT pg_temp.is(
  (SELECT detail FROM health.problems
   WHERE kind = 'serial_at_several_places' AND subject = 'SQLH-TWIN'),
  format('2 readings, the last at %s, at 10.0.0.1:502 unit 10 via sqlh_a; '
         || '1 readings, the last at %s, at 10.0.0.1:502 unit 10 via sqlh_d',
         now() - interval '30 minutes', now() - interval '20 minutes'),
  'an unregistered serial read at several places says each place and when it was read there');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s:%s %s %s %s', collector_id, endpoint_host, endpoint_port,
                            unit_id, serial, readings),
                     '; ' ORDER BY unit_id, serial)
   FROM health.place_serials),
  'sqlh_a 10.0.0.1:502 9 SQLH-0005 1; sqlh_a 10.0.0.1:502 9 SQLH-STRAY 1; '
  || 'sqlh_a 10.0.0.1:502 12 SQLS-A 3; sqlh_a 10.0.0.1:502 12 SQLS-B 2',
  'a place whose readings within the lookback carry several serials lists each, registered '
  || 'or not, and a place with one serial, or one more outside the lookback, is not listed');

SELECT pg_temp.is(
  (SELECT detail FROM health.problems
   WHERE kind = 'several_serials_at_place' AND subject = '10.0.0.1:502 unit 12 via sqlh_a'),
  format('SQLS-A: 3 readings, from %s to %s; SQLS-B: 2 readings, from %s to %s',
         now() - interval '50 minutes', now() - interval '10 minutes',
         now() - interval '40 minutes', now() - interval '20 minutes'),
  'several serials at a place say each serial''s readings and when, so interleaving shows');

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
-- that arrived five minutes ago; SQLF-0008 changed and sent the new names
-- again after a restart, both in one upload; SQLF-0009 changed in a batch
-- that arrived three hours ago, and sent the new names again in a later one;
-- SQLF-0000 changed in a batch that arrived two days ago, and sent the new
-- names again in one that arrived five minutes ago.
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
             ('SQLF-0007', 'sqlh_a', '10 days', 'SIM-SW2', 'SIM-F1'),
             ('SQLF-0008', 'sqlh_a', '3 days', 'SIM-SW1', 'SIM-F1'),
             ('SQLF-0008', 'sqlh_a', '2 hours', 'SIM-SW2', 'SIM-F1'),
             ('SQLF-0008', 'sqlh_a', '10 minutes', 'SIM-SW2', 'SIM-F1'),
             ('SQLF-0009', 'sqlh_c', '3 days', 'SIM-SW1', 'SIM-F1'),
             ('SQLF-0009', 'sqlh_c', '4 hours', 'SIM-SW2', 'SIM-F1'),
             ('SQLF-0009', 'sqlh_a', '10 minutes', 'SIM-SW2', 'SIM-F1'),
             ('SQLF-0000', 'sqlh_c_old', '3 days', 'SIM-SW1', 'SIM-F1'),
             ('SQLF-0000', 'sqlh_c_old', '2 days', 'SIM-SW2', 'SIM-F1'),
             ('SQLF-0000', 'sqlh_a', '10 minutes', 'SIM-SW2', 'SIM-F1')) v (s, c, i, sw, f1);

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s %s %s', serial, software, coalesce(firmware_1, 'NULL'),
                            changed), ', ' ORDER BY serial)
   FROM health.meter_firmware WHERE serial LIKE 'SQLF-%'),
  'SQLF-0000 SIM-SW2 SIM-F1 t, SQLF-0001 SIM-SW2 SIM-F1 t, SQLF-0002 SIM-SW1 SIM-F1 f, '
  || 'SQLF-0003 SIM-SW1 SIM-F1 f, SQLF-0004 SIM-SW2 SIM-F1 t, SQLF-0005 SIM-SW1 NULL t, '
  || 'SQLF-0006 SIM-SW2 SIM-F1 t, SQLF-0007 SIM-SW2 SIM-F1 t, SQLF-0008 SIM-SW2 SIM-F1 t, '
  || 'SQLF-0009 SIM-SW2 SIM-F1 t',
  'each serial''s latest names are shown, and whether they differ from an earlier record');

SELECT pg_temp.is(
  (SELECT format('%s %s %s %s', software, first_read_at, first_received_at, previous_read_at)
   FROM health.meter_firmware WHERE serial = 'SQLF-0009'),
  format('SIM-SW2 %s %s %s', now() - interval '4 hours', now() - interval '3 hours',
         now() - interval '3 days'),
  'a resend of the same names keeps when they were first read and arrived, and the names before');

SELECT pg_temp.is(
  (SELECT string_agg(subject, ', ' ORDER BY subject) FROM health.problems
   WHERE kind = 'firmware_changed'),
  'SQLF-0001, SQLF-0005, SQLF-0006, SQLF-0007, SQLF-0008, SQLF-0009',
  'a firmware change is flagged while the first record of the new names arrived within the '
  || 'lookback, whatever was resent after it, and unchanged names are not');

SELECT pg_temp.is(
  (SELECT detail FROM health.problems WHERE kind = 'firmware_changed' AND subject = 'SQLF-0005'),
  format('software SIM-SW1, firmware SIM-F1 / SIM-F2, modbus 0B03 (read %s) became '
         || 'software SIM-SW1, firmware (none) / SIM-F2, modbus 0B03 (read %s), '
         || 'at 10.0.0.1:502 unit 25 via sqlh_a',
         now() - interval '3 days', now() - interval '10 minutes'),
  'a firmware change''s problem says the names before and after, when each was read, and where');

-- Copies, on collector sqlh_e (last upload 5 minutes ago) and sqlh_f (last
-- upload 20 hours ago), at 10.0.0.5:502. Each meter's clock is set by the
-- meter time it reads now, so meter days do not hang on the hour the tests
-- run: most read 2026-06-15 12:00, so their 2026-06-14 snapshot was replaced
-- 12 hours ago by their clock and 2026-06-13's is outside the lookback.
SAVEPOINT copies;
SELECT admin.create_collector(c) FROM unnest(ARRAY['sqlh_e', 'sqlh_f']) c;
INSERT INTO b VALUES ('sqlh_e', pg_temp.upload('sqlh_e', '5 minutes', 0, 0, 0, 0)),
                     ('sqlh_f', pg_temp.upload('sqlh_f', '20 hours', 0, 0, 0, 0));

CREATE FUNCTION pg_temp.copy_endpoint(id text, collector text, ago interval, copy boolean,
                                      other boolean)
RETURNS bigint
LANGUAGE sql AS $$
  SELECT admin.register_endpoint(
    endpoint_id => id, valid_from => now() - ago, collector_id => collector, host => id,
    port => 502, framing => 'tcp', polled_by_other_system => other, timeout_ms => 1000,
    max_timeouts => 3, retries => 2, busy_backoff_ms => 500, reconnect_backoff_min_ms => 1000,
    reconnect_backoff_max_ms => 60000, interval_ms => 900000, copy => copy)
$$;

-- A target of this profile, in service for ten days.
CREATE FUNCTION pg_temp.copy_target(endpoint text, unit integer, profile text) RETURNS bigint
LANGUAGE sql AS $$
  SELECT admin.register_target(endpoint_id => endpoint, unit_id => unit,
    valid_from => now() - interval '10 days', profile => profile, interval_ms => NULL)
$$;

-- A meter-clock read `ago` at the endpoint's unit, through its collector's
-- batch, by a meter whose clock reads meter_now now.
CREATE FUNCTION pg_temp.clock(endpoint text, unit integer, serial text, profile text,
                              ago interval, meter_now timestamp)
RETURNS void
LANGUAGE sql AS $$
  INSERT INTO store.meter_clock_reads
  SELECT e.collector_id, e.host, e.port, unit, now() - ago, serial, profile, 2, meter_now - ago,
         b.batch
  FROM registry.endpoint_history e JOIN b ON b.collector = e.collector_id
  WHERE e.endpoint_id = endpoint AND e.period @> now()
$$;

-- An entry of the serial's store, stamped at meter_time, under one of its
-- profile's quantities in that store.
CREATE FUNCTION pg_temp.copied(serial text, profile text, store store.stored_store,
                               meter_time timestamp)
RETURNS void
LANGUAGE sql AS $$
  INSERT INTO store.stored_entries
    (meter_serial, store, register_key, meter_time, value, interval_s, profile, profile_version,
     product_code, slot, copied_at, endpoint_host, endpoint_port, unit_id, collector_id,
     batch_id)
  SELECT serial, copied.store, min(p.register_key), meter_time, 1.0,
         CASE WHEN copied.store = 'load_survey' THEN 1800 END, copied.profile, 2, 'P', 0,
         now(), 'h', 502, 1, 'sqlh_e', (SELECT batch FROM b WHERE collector = 'sqlh_e')
  FROM store.profile_stored p
  WHERE (p.profile, p.version, p.store) = (copied.profile, 2, copied.store)
$$;

-- sqlc_on copies since 200 days ago. sqlc_late was switched on 30 hours ago,
-- before the meter's 2026-06-14 snapshot was taken by its clock (36 hours
-- ago); sqlc_off copies nothing; sqlc_other is another system's; sqlc_quiet
-- is behind sqlh_f, which has not uploaded since the snapshot was replaced.
SELECT pg_temp.copy_endpoint('sqlc_on', 'sqlh_e', '200 days', true, false);
SELECT pg_temp.copy_endpoint('sqlc_late', 'sqlh_e', '10 days', false, false);
SELECT admin.change_endpoint(endpoint_id => 'sqlc_late', valid_from => now() - interval '30 hours',
  collector_id => 'sqlh_e', host => 'sqlc_late', port => 502, framing => 'tcp',
  polled_by_other_system => false, timeout_ms => 1000, max_timeouts => 3, retries => 2,
  busy_backoff_ms => 500, reconnect_backoff_min_ms => 1000, reconnect_backoff_max_ms => 60000,
  interval_ms => 900000, copy => true);
SELECT pg_temp.copy_endpoint('sqlc_off', 'sqlh_e', '10 days', false, false);
SELECT pg_temp.copy_endpoint('sqlc_other', 'sqlh_e', '10 days', true, true);
SELECT pg_temp.copy_endpoint('sqlc_quiet', 'sqlh_f', '10 days', true, false);

-- On sqlc_on: unit 1 missed 2026-06-14 (and 2026-06-12, outside the
-- lookback); unit 2 copied it, but its load survey stopped at 2026-06-05;
-- unit 3's clock passed midnight 30 minutes ago, inside the margin, and unit
-- 4's 90 minutes ago, past it; unit 5 was first seen 30 hours ago, after
-- 2026-06-14's snapshot; unit 6 is not seen yet; unit 7, a 500, keeps many
-- snapshots, was first seen 200 days ago, and its history and load survey
-- are behind.
SELECT pg_temp.copy_target('sqlc_on', u, CASE WHEN u = 7 THEN 'elite_500' ELSE 'elite_440' END)
FROM generate_series(1, 7) u;
SELECT pg_temp.copy_target(e, 1, 'elite_440')
FROM unnest(ARRAY['sqlc_late', 'sqlc_off', 'sqlc_other', 'sqlc_quiet']) e;

SELECT pg_temp.clock(e, u, s, p, a, m)
FROM (VALUES ('sqlc_on', 1, 'SQLC-0001', 'elite_440', '10 days'::interval,
              '2026-06-15 12:00'::timestamp),
             ('sqlc_on', 1, 'SQLC-0001', 'elite_440', '1 hour', '2026-06-15 12:00'),
             ('sqlc_on', 2, 'SQLC-0002', 'elite_440', '10 days', '2026-06-15 12:00'),
             ('sqlc_on', 3, 'SQLC-0003', 'elite_440', '10 days', '2026-06-15 00:30'),
             ('sqlc_on', 4, 'SQLC-0004', 'elite_440', '10 days', '2026-06-15 01:30'),
             ('sqlc_on', 5, 'SQLC-0005', 'elite_440', '30 hours', '2026-06-15 12:00'),
             ('sqlc_on', 7, 'SQLC-5001', 'elite_500', '200 days', '2026-06-15 12:00'),
             ('sqlc_late', 1, 'SQLC-0201', 'elite_440', '10 days', '2026-06-15 12:00'),
             ('sqlc_off', 1, 'SQLC-0101', 'elite_440', '10 days', '2026-06-15 12:00'),
             ('sqlc_other', 1, 'SQLC-0301', 'elite_440', '10 days', '2026-06-15 12:00'),
             ('sqlc_quiet', 1, 'SQLC-0401', 'elite_440', '21 hours', '2026-06-15 12:00'),
             ('sqlc_quiet', 1, 'SQLC-0401', 'elite_440', '10 days', '2026-06-15 12:00'))
       v (e, u, s, p, a, m);

SELECT pg_temp.copied(s, p, st::store.stored_store, t)
FROM (VALUES ('SQLC-0001', 'elite_440', 'snapshot', '2026-06-13 00:00'::timestamp),
             ('SQLC-0001', 'elite_440', 'snapshot', '2026-06-11 00:00'),
             ('SQLC-0001', 'elite_440', 'load_survey', '2026-06-15 11:30'),
             ('SQLC-0001', 'elite_440', 'history', '2026-06-01 00:00'),
             ('SQLC-0002', 'elite_440', 'snapshot', '2026-06-14 00:00'),
             ('SQLC-0002', 'elite_440', 'load_survey', '2026-06-05 23:30'),
             ('SQLC-0002', 'elite_440', 'history', '2026-06-01 00:00'),
             ('SQLC-0003', 'elite_440', 'snapshot', '2026-06-13 00:00'),
             ('SQLC-0003', 'elite_440', 'load_survey', '2026-06-15 00:00'),
             ('SQLC-0003', 'elite_440', 'history', '2026-06-01 00:00'),
             ('SQLC-0004', 'elite_440', 'snapshot', '2026-06-13 00:00'),
             ('SQLC-0004', 'elite_440', 'load_survey', '2026-06-15 01:00'),
             ('SQLC-0004', 'elite_440', 'history', '2026-06-01 00:00'),
             ('SQLC-5001', 'elite_500', 'snapshot', '2026-06-10 00:00'),
             ('SQLC-5001', 'elite_500', 'load_survey', '2026-05-01 00:00'),
             ('SQLC-5001', 'elite_500', 'history', '2026-03-01 00:00'),
             ('SQLC-0401', 'elite_440', 'load_survey', '2026-06-14 15:00')) v (s, p, st, t);

SELECT pg_temp.is(
  (SELECT string_agg(format('%s/%s %s %s %s', endpoint_id, unit_id, coalesce(serial, '-'),
                            copying_since = now() - interval '30 hours',
                            last_upload_at = now() - interval '5 minutes'),
                     ', ' ORDER BY endpoint_id, unit_id)
   FROM health.copy_targets WHERE endpoint_id LIKE 'sqlc_%'),
  'sqlc_late/1 SQLC-0201 t t, sqlc_on/1 SQLC-0001 f t, sqlc_on/2 SQLC-0002 f t, '
  || 'sqlc_on/3 SQLC-0003 f t, sqlc_on/4 SQLC-0004 f t, sqlc_on/5 SQLC-0005 f t, '
  || 'sqlc_on/6 - f t, sqlc_on/7 SQLC-5001 f t, sqlc_quiet/1 SQLC-0401 f f',
  'a target is copied while its endpoint copies and no other system polls it, with since when '
  || 'it has copied, the serial its last meter-clock read found, and its collector''s last upload');

SELECT pg_temp.is(
  (SELECT format('%s %s %s',
                 meter_offset = '2026-06-15 12:00'::timestamp - (now() AT TIME ZONE 'UTC'),
                 clock_read_at = now() - interval '1 hour',
                 first_seen_at = now() - interval '10 days')
   FROM health.copy_targets WHERE serial = 'SQLC-0001'),
  't t t',
  'a copied target shows its meter''s offset from UTC as last read, and when it was first seen');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s', serial, meter_day), ', ' ORDER BY serial, meter_day)
   FROM health.missed_snapshots),
  'SQLC-0001 2026-06-14, SQLC-0004 2026-06-14',
  'a copied 440''s snapshot day is missed once the meter replaced it, past the margin, before '
  || 'the last upload, within the lookback; not before copying began or the meter was seen, '
  || 'not while copying is off, not for another system''s endpoint or a meter not seen');

SELECT pg_temp.is(
  (SELECT detail FROM health.problems WHERE kind = 'snapshot_missed' AND subject = 'SQLC-0001'),
  format('no snapshot copied for meter day 2026-06-14, now replaced on the meter; its clock read '
         || '%s from UTC at %s; at sqlc_on:502 unit 1 via sqlh_e',
         '2026-06-15 12:00'::timestamp - (now() AT TIME ZONE 'UTC'), now() - interval '1 hour'),
  'a missed snapshot''s problem says the meter days, the meter''s clock as read, and where');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s %s', serial, store, coalesce(newest_entry::text, '-')), ', '
                     ORDER BY serial, store)
   FROM health.copy_stores WHERE serial IN ('SQLC-0002', 'SQLC-0005', 'SQLC-5001')),
  'SQLC-0002 history 2026-06-01 00:00:00, SQLC-0002 load_survey 2026-06-05 23:30:00, '
  || 'SQLC-0005 history -, SQLC-0005 load_survey -, '
  || 'SQLC-5001 history 2026-03-01 00:00:00, SQLC-5001 snapshot 2026-06-10 00:00:00, '
  || 'SQLC-5001 load_survey 2026-05-01 00:00:00',
  'each copied meter''s stores are judged per its profile, with the newest entry copied, a 440''s '
  || 'snapshot left to missed_snapshots');

SELECT pg_temp.is(
  (SELECT string_agg(subject, ', ' ORDER BY subject) FROM health.problems
   WHERE kind IN ('snapshot_missed', 'copy_behind')),
  'SQLC-0001, SQLC-0002 load_survey, SQLC-0004, SQLC-5001 history, SQLC-5001 load_survey',
  'a store is behind when its newest copied entry is older than its model''s behind_after at '
  || 'the last upload, and the endpoint copied and the meter was seen since before then; a '
  || '500''s snapshots are judged as a store, not night by night');

SELECT pg_temp.is(
  (SELECT detail FROM health.problems WHERE kind = 'copy_behind' AND subject = 'SQLC-5001 history'),
  format('newest history entry copied 2026-03-01 00:00:00, more than 62 days before the meter''s '
         || 'clock at the last upload (%s); at sqlc_on:502 unit 7 via sqlh_e, profile elite_500',
         '2026-06-15 11:55'::timestamp),
  'a store behind says its newest entry, the threshold, the meter''s clock at the last upload, '
  || 'and where');

SAVEPOINT caught_up;
SELECT pg_temp.copied('SQLC-0001', 'elite_440', 'snapshot', '2026-06-14 00:00');
SELECT pg_temp.copied('SQLC-5001', 'elite_500', 'load_survey', '2026-05-17 00:00');
SELECT pg_temp.is(
  (SELECT string_agg(subject, ', ' ORDER BY subject) FROM health.problems
   WHERE kind IN ('snapshot_missed', 'copy_behind')),
  'SQLC-0002 load_survey, SQLC-0004, SQLC-5001 history',
  'a snapshot copied clears its day, and an entry stamped within behind_after its store');
ROLLBACK TO SAVEPOINT caught_up;

SELECT pg_temp.is(pg_temp.unkeyed_scans('SELECT * FROM health.missed_snapshots'), NULL,
  'health.missed_snapshots finds clock reads, uploads and snapshot entries by index');
SELECT pg_temp.is(pg_temp.unkeyed_scans('SELECT * FROM health.copy_stores'), NULL,
  'health.copy_stores finds clock reads, uploads and entries by index');

SELECT admin.set_health_thresholds(collector_silent_after => '1 hour',
  meter_silent_intervals => 4, backlog_near_capacity => 0.8, lookback => '4 days',
  endpoint_error_rate => 0.05, snapshot_missed_margin => '2 hours',
  history_behind_after => '120 days', snapshot_behind_after_elite_500 => '14 days',
  load_survey_behind_after_elite_440 => '7 days', load_survey_behind_after_elite_500 => '50 days');
SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s', serial, meter_day), ', ' ORDER BY serial, meter_day)
   FROM health.missed_snapshots WHERE serial IN ('SQLC-0001', 'SQLC-0004')),
  'SQLC-0001 2026-06-12, SQLC-0001 2026-06-14, SQLC-0004 2026-06-10, SQLC-0004 2026-06-11, '
  || 'SQLC-0004 2026-06-12',
  'missed snapshot days are judged by the margin and lookback in force');
SELECT pg_temp.is(
  (SELECT string_agg(subject, ', ' ORDER BY subject) FROM health.problems
   WHERE kind = 'copy_behind'),
  'SQLC-0002 load_survey',
  'a store behind is judged by its model''s behind_after in force');
ROLLBACK TO SAVEPOINT copies;

SELECT admin.set_health_thresholds(collector_silent_after => '3 hours',
  meter_silent_intervals => 10, backlog_near_capacity => 0.9, lookback => '4 days',
  endpoint_error_rate => 0.2, snapshot_missed_margin => '1 hour',
  history_behind_after => '62 days', snapshot_behind_after_elite_500 => '14 days',
  load_survey_behind_after_elite_440 => '7 days', load_survey_behind_after_elite_500 => '30 days');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s', kind, subject), '; ' ORDER BY kind, subject)
   FROM health.problems WHERE kind IN ('collector_silent', 'meter_silent', 'backlog_near_capacity',
                                       'unregistered_serial', 'serial_at_several_places',
                                       'target_silent')),
  'serial_at_several_places SQLH-STRAY; '
  || 'serial_at_several_places SQLH-TWIN; '
  || 'target_silent sqlh_b_ep unit 1; target_silent sqlh_d_ep unit 13; '
  || 'target_silent sqlh_d_ep unit 14; target_silent sqlh_d_ep unit 15; '
  || 'target_silent sqlh_m_ep unit 2; '
  || 'unregistered_serial SQLH-OLD-STRAY; '
  || 'unregistered_serial SQLH-STRAY; unregistered_serial SQLH-TWIN; '
  || 'unregistered_serial SQLS-A; unregistered_serial SQLS-B',
  'the latest thresholds set are the ones judged by');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s', serial, readings), ', ' ORDER BY serial)
   FROM health.place_serials WHERE unit_id = 9),
  'SQLH-0005 1, SQLH-OLD-STRAY 1, SQLH-STRAY 1',
  'the serials at a place are judged by the lookback in force');

SELECT pg_temp.is(
  (SELECT string_agg(subject, ', ' ORDER BY subject) FROM health.problems
   WHERE kind = 'firmware_changed'),
  'SQLF-0000, SQLF-0001, SQLF-0004, SQLF-0005, SQLF-0006, SQLF-0007, SQLF-0008, SQLF-0009',
  'a firmware change is judged by the lookback in force');

SELECT pg_temp.is(
  (SELECT format('%s %s %s %s %s', collector_silent_after, meter_silent_intervals,
                 backlog_near_capacity, lookback, endpoint_error_rate)
   FROM health.thresholds),
  '03:00:00 10 0.9 4 days 0.2',
  'health.thresholds shows the thresholds in force');

ROLLBACK;
