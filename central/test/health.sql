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

CREATE FUNCTION pg_temp.reading(serial text, batch uuid, ago interval) RETURNS void
LANGUAGE sql AS $$
  INSERT INTO store.readings
  SELECT serial, 'active_energy_import', now() - ago, 1.0, 'Wh', '{0,0}', 'elite_440', '10.0.0.1',
         502, 1, b.collector_id, batch
  FROM store.batches b WHERE b.batch_id = batch
$$;

CREATE FUNCTION pg_temp.missed(serial text, batch uuid, ago interval, reason store.missed_reason)
RETURNS void
LANGUAGE sql AS $$
  INSERT INTO store.missed_reads
  SELECT serial, 'active_energy_import', now() - ago, reason, NULL, NULL, 3, NULL, 'elite_440',
         '10.0.0.1', 502, 1, b.collector_id, batch
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

SELECT pg_temp.reading('SQLH-0001', (SELECT batch FROM b WHERE collector = 'sqlh_a'), '5 minutes');
SELECT pg_temp.reading('SQLH-0002', (SELECT batch FROM b WHERE collector = 'sqlh_a'), '2 hours');
SELECT pg_temp.reading('SQLH-0003', (SELECT batch FROM b WHERE collector = 'sqlh_a'), '2 hours');
SELECT pg_temp.reading('SQLH-0008', (SELECT batch FROM b WHERE collector = 'sqlh_a'), '47 hours');
SELECT pg_temp.reading('SQLH-STRAY', (SELECT batch FROM b WHERE collector = 'sqlh_a'), '1 hour');
SELECT pg_temp.reading('SQLH-OLD-STRAY', (SELECT batch FROM b WHERE collector = 'sqlh_a'), '3 days');
SELECT pg_temp.missed('SQLH-0002', (SELECT batch FROM b WHERE collector = 'sqlh_a'), i, r)
FROM (VALUES ('10 minutes'::interval, 'timeout'::store.missed_reason), ('20 minutes', 'timeout'),
             ('30 minutes', 'exception'), ('2 days', 'timeout')) v (i, r);

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s', kind, subject), '; ' ORDER BY kind, subject)
   FROM health.problems),
  'backlog_discarded sqlh_d; backlog_near_capacity sqlh_a; backlog_quarantined sqlh_a; '
  || 'backlog_refused sqlh_d; collector_silent sqlh_b; meter_silent SQLH-0002; '
  || 'unregistered_serial SQLH-STRAY',
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
  'a meter shows its last reading and its missed reads within the lookback, by reason');

SELECT pg_temp.is(
  (SELECT format('%s %s %s %s %s %s %s %s', in_service, endpoints,
                 last_upload_at = now() - interval '5 minutes',
                 last_reading_at = now() - interval '5 minutes', clock_source, backlog_used,
                 missed_reads, missed_by_reason)
   FROM health.collectors WHERE collector_id = 'sqlh_a'),
  't 2 t t ntp 0.8500 3 {"timeout": 2, "exception": 1}',
  'a collector shows its last upload and reading, clock, backlog and missed reads');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s %s', collector_id, in_service, silent), ', '
                     ORDER BY collector_id)
   FROM health.collectors WHERE collector_id LIKE 'sqlh_%'),
  'sqlh_a t f, sqlh_b t t, sqlh_c f f, sqlh_d t f',
  'a collector is judged only while it has an endpoint in service');

SELECT pg_temp.is(
  (SELECT format('%s %s', serial, readings) FROM health.unregistered_serials),
  'SQLH-STRAY 1',
  'only serials read within the lookback are listed as unregistered');

SELECT admin.set_health_thresholds(collector_silent_after => '3 hours',
  meter_silent_intervals => 10, backlog_near_capacity => 0.9, lookback => '4 days');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s', kind, subject), '; ' ORDER BY kind, subject)
   FROM health.problems WHERE kind IN ('collector_silent', 'meter_silent', 'backlog_near_capacity',
                                       'unregistered_serial')),
  'meter_silent SQLH-0007; unregistered_serial SQLH-OLD-STRAY; unregistered_serial SQLH-STRAY',
  'the latest thresholds set are the ones judged by');

SELECT pg_temp.is(
  (SELECT format('%s %s %s %s', collector_silent_after, meter_silent_intervals,
                 backlog_near_capacity, lookback)
   FROM health.thresholds),
  '03:00:00 10 0.9 4 days',
  'health.thresholds shows the thresholds in force');

ROLLBACK;
