-- Clock checks as read: the NTP figures store.clock_offsets computes, the
-- reference ids it decodes, the upload fallback's one-sided bound, which
-- readings no answered check grounds, and the collectors health flags for
-- going unchecked. Checks, batches and readings are inserted directly, most
-- with times relative to now().

\ir lib/assert.sql

BEGIN;

SELECT admin.set_health_thresholds(collector_silent_after => '1 hour',
  meter_silent_intervals => 4, backlog_near_capacity => 0.8, lookback => '1 day',
  endpoint_error_rate => 0.05);

-- Collectors registered `ago`, without the roles admin.create_collector makes.
INSERT INTO store.collectors (id, created_at)
SELECT c, now() - ago
FROM (VALUES ('sqlc_math', '10 days'::interval), ('sqlc_fresh', '1 hour'), ('sqlc_ok', '10 days'),
             ('sqlc_old', '10 days'), ('sqlc_never', '10 days'), ('sqlc_kiss', '10 days'),
             ('sqlc_skewed', '10 days'), ('sqlc_silent', '10 days'), ('sqlc_idle', '10 days'),
             ('sqlc_other', '10 days')) v (c, ago);

-- One batch per collector, received and uploaded `ago`, sent `ahead` earlier
-- by the collector's clock.
CREATE FUNCTION pg_temp.upload(collector text, ago interval, ahead interval) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  id uuid := gen_random_uuid();
BEGIN
  INSERT INTO store.batches VALUES (id, collector, now() - ago, 'unsynced', NULL, 0, 0);
  INSERT INTO store.uploads
    (batch_id, collector_id, received_at, sent_at, backlog_events, backlog_bytes, backlog_batches,
     backlog_oldest, backlog_max_bytes, backlog_refused, backlog_discarded_files,
     backlog_quarantined, readings_inserted, readings_duplicate, readings_conflicting,
     missed_reads_inserted, missed_reads_duplicate)
  VALUES (id, collector, now() - ago, now() - ago - ahead, 0, 0, 0, NULL, 1000, 0, 0, 0, 0, 0, 0,
          0, 0);
  RETURN id;
END
$$;

CREATE TEMP TABLE b (cid text PRIMARY KEY, bid uuid);
INSERT INTO b SELECT id, pg_temp.upload(id, '5 minutes', '0 seconds')
FROM store.collectors WHERE id LIKE 'sqlc\_%' AND id <> 'sqlc_silent';
INSERT INTO b VALUES ('sqlc_silent', pg_temp.upload('sqlc_silent', '3 days', '0 seconds'));

-- A check as the collector sent it: t1 and t4 by its clock, t2 and t3 as Unix time.
CREATE FUNCTION pg_temp.clock_check(collector text, outcome store.clock_check_outcome, t1 timestamptz,
                              t2 numeric, t3 numeric, t4 timestamptz, stratum smallint,
                              reference_id bigint)
RETURNS void
LANGUAGE sql AS $$
  INSERT INTO store.clock_checks
    (collector_id, t1, t4, trigger, server, outcome, t2_unix, t3_unix, address, stratum, leap,
     reference_id, batch_id)
  SELECT collector, t1, t4, 'daily', E'pool.ntp.org\n', outcome, t2, t3,
         CASE WHEN reference_id IS NOT NULL THEN '192.0.2.123'::inet END, stratum,
         CASE WHEN outcome = 'answered' THEN 0 END, reference_id, b.bid
  FROM b WHERE b.cid = collector
$$;

-- An answered check `ago`, the collector's clock `behind` the server's, 10 ms each way.
CREATE FUNCTION pg_temp.answered(collector text, ago interval, behind interval) RETURNS void
LANGUAGE sql AS $$
  SELECT pg_temp.clock_check(collector, 'answered', now() - ago - behind,
                       extract(epoch FROM now() - ago + interval '10 milliseconds'),
                       extract(epoch FROM now() - ago + interval '10 milliseconds'),
                       now() - ago - behind + interval '20 milliseconds', 2::smallint, 3221226115)
$$;

CREATE FUNCTION pg_temp.failed(collector text, outcome store.clock_check_outcome, ago interval,
                               reference_id bigint)
RETURNS void
LANGUAGE sql AS $$
  SELECT pg_temp.clock_check(collector, outcome, now() - ago, NULL, NULL,
                       now() - ago + interval '5 seconds', NULL, reference_id)
$$;

-- The NTP figures, exact.
SELECT pg_temp.clock_check('sqlc_math', 'answered', '2026-11-01T00:00:04.000123Z', 1793491208.215003051,
                     1793491208.215047312, '2026-11-01T00:00:04.031877Z', 2::smallint, 3221226115);
SELECT pg_temp.clock_check('sqlc_math', 'answered', '2026-11-01T00:10:00Z', 1793491790.001,
                     1793491790.002, '2026-11-01T00:10:00.003Z', 1::smallint, 1196446464);
SELECT pg_temp.clock_check('sqlc_math', 'answered', '2026-11-01T00:20:10Z', 1793492400.999999999,
                     1793492400.999999999, '2026-11-01T00:20:10.000002Z', 3::smallint, 16909060);

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s %s %s %s %s', t1, t2, t3, offset_seconds, delay_seconds,
                            error_bound_seconds), '; ' ORDER BY t1)
   FROM store.clock_offsets WHERE collector_id = 'sqlc_math'),
  '2026-11-01 00:00:04.000123+00 2026-11-01 00:00:08.215003+00 2026-11-01 00:00:08.215047+00 '
  || '4.1990251815 0.031709739 0.0158548695; '
  || '2026-11-01 00:10:00+00 2026-11-01 00:09:50.001+00 2026-11-01 00:09:50.002+00 -10 0.002 0.001; '
  || '2026-11-01 00:20:10+00 2026-11-01 00:20:00.999999+00 2026-11-01 00:20:00.999999+00 '
  || '-9.000001001 0.000002 0.000001',
  'an answered check''s offset is ((t2 - t1) + (t3 - t4)) / 2, its delay (t4 - t1) - (t3 - t2) '
  || 'and its error bound delay / 2, to the nanosecond; t2 and t3 shown cut to microseconds');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s', stratum, reference), '; ' ORDER BY t1)
   FROM store.clock_offsets WHERE collector_id = 'sqlc_math'),
  '2 192.0.2.131; 1 GPS; 3 1.2.3.4',
  'a reference id reads as an address above stratum 1, and as its source at stratum 1');

SELECT pg_temp.failed('sqlc_math', 'kiss_of_death', '1 hour', 1380013125);
SELECT pg_temp.failed('sqlc_math', 'kiss_of_death', '2 hours', 16909060);
SELECT pg_temp.failed('sqlc_math', 'timeout', '3 hours', NULL);

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s', outcome, reference), '; ' ORDER BY t1 DESC)
   FROM store.clock_check_references WHERE collector_id = 'sqlc_math' AND outcome <> 'answered'),
  'kiss_of_death RATE; kiss_of_death ????',
  'a kiss-o''-death''s reference id reads as its kiss code, anything unprintable as ?');

SELECT pg_temp.is(
  (SELECT count(*) FROM store.clock_offsets WHERE collector_id = 'sqlc_math'),
  3::bigint,
  'only answered checks have an offset');

-- The upload fallback: sqlc_other's clock 3.5 s behind the store's, by its upload.
UPDATE b SET bid = pg_temp.upload('sqlc_other', '1 minute', '3.5 seconds')
WHERE cid = 'sqlc_other';

SELECT pg_temp.is(
  (SELECT offset_at_most_seconds FROM store.upload_clock_offsets
   WHERE collector_id = 'sqlc_other' ORDER BY received_at DESC LIMIT 1),
  3.5,
  'an upload bounds the offset from one side: received_at - sent_at');

-- Grounding: sqlc_ok's answered check an hour ago; a timeout of sqlc_old's
-- grounds nothing; sqlc_other has no answered check.
CREATE FUNCTION pg_temp.reading(collector text, serial text, at timestamptz) RETURNS void
LANGUAGE sql AS $$
  INSERT INTO store.readings
  SELECT serial, 'active_energy_import', at, 1.0, 'elite_440', '10.0.0.1', 502, 1, collector,
         b.bid, 'ELITE440-445', 1
  FROM b WHERE b.cid = collector
$$;

SELECT pg_temp.answered('sqlc_ok', '1 hour', '0 seconds');
SELECT pg_temp.answered('sqlc_old', '49 hours', '0 seconds');
SELECT pg_temp.failed('sqlc_old', 'timeout', '1 hour', NULL);

SELECT pg_temp.reading('sqlc_ok', s, now() - interval '1 hour' + at)
FROM (VALUES ('SQLC-BEFORE-IN', interval '-47:59'),
             ('SQLC-BEFORE-OUT', interval '-48:01'),
             ('SQLC-AFTER-IN', interval '47:59'),
             ('SQLC-AFTER-OUT', interval '48:01')) v (s, at);
SELECT pg_temp.reading('sqlc_old', 'SQLC-NEAR-TIMEOUT', now() - interval '30 minutes');
SELECT pg_temp.reading('sqlc_other', 'SQLC-OTHER', now() - interval '1 hour');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s %s', meter_serial, previous_check_at IS NOT NULL,
                            next_check_at IS NOT NULL), ', ' ORDER BY meter_serial)
   FROM store.ungrounded_readings WHERE meter_serial LIKE 'SQLC-%'),
  'SQLC-AFTER-OUT t f, SQLC-BEFORE-OUT f t, SQLC-NEAR-TIMEOUT t f, SQLC-OTHER f f',
  'a reading is ungrounded with no answered check by its collector within 48 hours either side, '
  || 'and names the nearest ones');

-- Health. Every collector but sqlc_idle has an endpoint in service.
SELECT admin.register_endpoint(
  endpoint_id => id || '_ep', valid_from => now() - interval '2 days', collector_id => id,
  host => '10.0.0.1', port => 502, framing => 'tcp', polled_by_other_system => false,
  timeout_ms => 1000, max_timeouts => 3, retries => 2, busy_backoff_ms => 500,
  reconnect_backoff_min_ms => 1000, reconnect_backoff_max_ms => 60000, interval_ms => 900000)
FROM store.collectors WHERE id LIKE 'sqlc\_%' AND id <> 'sqlc_idle';

-- sqlc_kiss's last answer 3 days ago, then RATE; sqlc_skewed's clock a week
-- behind, answered an hour ago; sqlc_silent and sqlc_idle never checked.
SELECT pg_temp.answered('sqlc_kiss', '3 days', '0 seconds');
SELECT pg_temp.failed('sqlc_kiss', 'kiss_of_death', '2 hours', 1380013125);
SELECT pg_temp.answered('sqlc_skewed', '1 hour', '7 days');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s', collector_id, unchecked), ', ' ORDER BY collector_id)
   FROM health.collector_clocks WHERE collector_id LIKE 'sqlc\_%'),
  'sqlc_fresh f, sqlc_idle f, sqlc_kiss t, sqlc_math t, sqlc_never t, sqlc_ok f, sqlc_old t, '
  || 'sqlc_other t, sqlc_silent f, sqlc_skewed f',
  'a collector in service and not silent is unchecked with no answered check in 48 hours by '
  || 'the server''s clock, counted from when it was registered');

SELECT pg_temp.is(
  (SELECT format('%s %s %s %s %s', last_outcome, last_check_at = now() - interval '1 hour 7 days',
                 last_answered_at = now() - interval '1 hour' + interval '10 milliseconds',
                 offset_seconds, error_bound_seconds)
   FROM health.collector_clocks WHERE collector_id = 'sqlc_skewed'),
  'answered t t 604800 0.01',
  'a collector''s clock view gives its last check and the offset of its last answered one');

SELECT pg_temp.is(
  (SELECT upload_offset_at_most_seconds FROM health.collector_clocks
   WHERE collector_id = 'sqlc_other'),
  3.5,
  'and the offset bound of its latest upload');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s', kind, subject), '; ' ORDER BY subject)
   FROM health.problems WHERE subject LIKE 'sqlc\_%'),
  'clock_unchecked sqlc_kiss; clock_unchecked sqlc_math; clock_unchecked sqlc_never; '
  || 'clock_unchecked sqlc_old; clock_unchecked sqlc_other; collector_silent sqlc_silent',
  'each unchecked collector is a problem, and a silent one only silent');

SELECT pg_temp.is(
  (SELECT string_agg(detail, '; ' ORDER BY subject) FROM health.problems
   WHERE kind = 'clock_unchecked' AND subject IN ('sqlc_kiss', 'sqlc_never', 'sqlc_old')),
  format('no answered clock check since %s; the last check, at %s by its clock, was '
         || 'kiss_of_death RATE from pool.ntp.org?; ',
         now() - interval '3 days' + interval '10 milliseconds', now() - interval '2 hours')
  || 'no clock check since it was registered; '
  || format('no answered clock check since %s; the last check, at %s by its clock, was '
            || 'timeout from pool.ntp.org?',
            now() - interval '49 hours' + interval '10 milliseconds', now() - interval '1 hour'),
  'an unchecked collector''s problem says since when, and what its last check was');

ROLLBACK;
