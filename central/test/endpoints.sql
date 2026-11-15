-- Per-endpoint health: the reads due at each registered endpoint within the
-- lookback, taken and missed, its error rate, and the problem it raises past
-- the threshold. Batches, readings and missed reads are inserted directly,
-- with times relative to now().

\ir lib/assert.sql

BEGIN;

SELECT admin.set_health_thresholds(collector_silent_after => '1 hour',
  meter_silent_intervals => 4, backlog_near_capacity => 0.8, lookback => '1 day',
  endpoint_error_rate => 0.1);

INSERT INTO store.collectors (id) VALUES ('sqlp_a'), ('sqlp_b');

CREATE TEMP TABLE b (collector text PRIMARY KEY, bid uuid NOT NULL);
INSERT INTO b SELECT c, gen_random_uuid() FROM unnest(ARRAY['sqlp_a', 'sqlp_b']) c;
INSERT INTO store.batches SELECT bid, collector, now(), 'ntp', now(), 0, 0 FROM b;

CREATE FUNCTION pg_temp.endpoint(id text, host text, other boolean) RETURNS bigint
LANGUAGE sql AS $$
  SELECT admin.register_endpoint(
    endpoint_id => id, valid_from => now() - interval '3 days', collector_id => 'sqlp_a',
    host => host, port => 502, framing => 'tcp', polled_by_other_system => other,
    timeout_ms => 1000, max_timeouts => 3, retries => 2, busy_backoff_ms => 500,
    reconnect_backoff_min_ms => 1000, reconnect_backoff_max_ms => 60000, interval_ms => 900000)
$$;

-- n readings at host:502 by collector who, a minute apart, the last `ago`.
CREATE FUNCTION pg_temp.readings(who text, host text, n integer, ago interval)
RETURNS void
LANGUAGE sql AS $$
  INSERT INTO store.readings
    (meter_serial, register_key, read_at, value, profile, profile_version, endpoint_host,
     endpoint_port, unit_id, product_code, collector_id, batch_id)
  SELECT 'SQLP-' || host, 'active_energy_import', now() - ago - i * interval '1 minute', 1,
         'elite_440', 1, host, 502, 1, 'ELITE440-445', who, b.bid
  FROM generate_series(0, n - 1) i
  JOIN b ON b.collector = who
$$;

-- n missed reads for reason at host:502 by collector who, a minute apart, the last `ago`.
CREATE FUNCTION pg_temp.missed(who text, host text, n integer, ago interval,
                               reason store.missed_reason)
RETURNS void
LANGUAGE sql AS $$
  INSERT INTO store.missed_reads
    (meter_serial, register_key, read_at, reason, attempts, profile, profile_version,
     endpoint_host, endpoint_port, unit_id, collector_id, batch_id)
  SELECT NULL, 'active_energy_import', now() - ago - i * interval '1 minute' - interval '1 second',
         reason, 3, 'elite_440', 1, host, 502, 1, who, b.bid
  FROM generate_series(0, n - 1) i
  JOIN b ON b.collector = who
$$;

SELECT pg_temp.endpoint('sqlp_steady', '10.0.1.1', false);
SELECT pg_temp.endpoint('sqlp_flaky', '10.0.1.2', false);
SELECT pg_temp.endpoint('sqlp_edge', '10.0.1.3', false);
SELECT pg_temp.endpoint('sqlp_meter_side', '10.0.1.4', false);
SELECT pg_temp.endpoint('sqlp_moved', '10.0.1.5', false);
SELECT pg_temp.endpoint('sqlp_other', '10.0.1.7', true);
SELECT pg_temp.endpoint('sqlp_retired', '10.0.1.8', false);
SELECT pg_temp.endpoint('sqlp_quiet', '10.0.1.9', false);

-- Readdressed from .5 to .6 an hour ago; retired an hour ago.
SELECT admin.change_endpoint(
  endpoint_id => 'sqlp_moved', valid_from => now() - interval '1 hour', collector_id => 'sqlp_a',
  host => '10.0.1.6', port => 502, framing => 'tcp', polled_by_other_system => false,
  timeout_ms => 1000, max_timeouts => 3, retries => 2, busy_backoff_ms => 500,
  reconnect_backoff_min_ms => 1000, reconnect_backoff_max_ms => 60000, interval_ms => 900000);
SELECT admin.retire_endpoint('sqlp_retired', now() - interval '1 hour');

-- steady: 1 timeout in 100, and a day-old burst outside the lookback;
-- another collector's reads at the same host and port are not its.
SELECT pg_temp.readings('sqlp_a', '10.0.1.1', 99, '5 minutes');
SELECT pg_temp.missed('sqlp_a', '10.0.1.1', 1, '5 minutes', 'timeout');
SELECT pg_temp.missed('sqlp_a', '10.0.1.1', 50, '2 days', 'timeout');
SELECT pg_temp.missed('sqlp_b', '10.0.1.1', 50, '5 minutes', 'unreachable');
-- flaky: 3 failures in 10.
SELECT pg_temp.readings('sqlp_a', '10.0.1.2', 7, '5 minutes');
SELECT pg_temp.missed('sqlp_a', '10.0.1.2', 2, '5 minutes', 'timeout');
SELECT pg_temp.missed('sqlp_a', '10.0.1.2', 1, '30 minutes', 'exception');
-- edge: exactly the threshold, 1 in 10.
SELECT pg_temp.readings('sqlp_a', '10.0.1.3', 9, '5 minutes');
SELECT pg_temp.missed('sqlp_a', '10.0.1.3', 1, '5 minutes', 'closed');
-- meter_side: the meter answered, with words that do not decode or the wrong profile.
SELECT pg_temp.readings('sqlp_a', '10.0.1.4', 2, '5 minutes');
SELECT pg_temp.missed('sqlp_a', '10.0.1.4', 2, '5 minutes', 'profile_mismatch');
SELECT pg_temp.missed('sqlp_a', '10.0.1.4', 1, '30 minutes', 'decode');
-- moved: at .5 before the move counts, at .5 after it does not, at .6 after it does.
SELECT pg_temp.readings('sqlp_a', '10.0.1.5', 3, '2 hours');
SELECT pg_temp.missed('sqlp_a', '10.0.1.5', 1, '2 hours', 'timeout');
SELECT pg_temp.missed('sqlp_a', '10.0.1.5', 20, '5 minutes', 'timeout');
SELECT pg_temp.readings('sqlp_a', '10.0.1.5', 20, '5 minutes');
SELECT pg_temp.readings('sqlp_a', '10.0.1.6', 4, '5 minutes');
-- other and retired: failing, but not ours to judge, or not in service now.
SELECT pg_temp.missed('sqlp_a', '10.0.1.7', 5, '5 minutes', 'timeout');
SELECT pg_temp.missed('sqlp_a', '10.0.1.8', 2, '2 hours', 'timeout');
SELECT pg_temp.missed('sqlp_a', '10.0.1.8', 30, '5 minutes', 'timeout');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s:%s %s %s %s %s %s %s', endpoint_id, host, port, readings,
                            missed_reads, failed_reads, missed_by_reason,
                            coalesce(error_rate::text, 'none'), erroring),
                     '; ' ORDER BY endpoint_id)
   FROM health.endpoints WHERE endpoint_id LIKE 'sqlp_%'),
  'sqlp_edge 10.0.1.3:502 9 1 1 {"closed": 1} 0.1000 t; '
  || 'sqlp_flaky 10.0.1.2:502 7 3 3 {"timeout": 2, "exception": 1} 0.3000 t; '
  || 'sqlp_meter_side 10.0.1.4:502 2 3 0 {"decode": 1, "profile_mismatch": 2} 0.0000 f; '
  || 'sqlp_moved 10.0.1.6:502 7 1 1 {"timeout": 1} 0.1250 t; '
  || 'sqlp_other 10.0.1.7:502 0 5 5 {"timeout": 5} 1.0000 f; '
  || 'sqlp_quiet 10.0.1.9:502 0 0 0 {} none f; '
  || 'sqlp_retired 10.0.1.8:502 0 2 2 {"timeout": 2} 1.0000 f; '
  || 'sqlp_steady 10.0.1.1:502 99 1 1 {"timeout": 1} 0.0100 f',
  'per endpoint, the reads due within the lookback at each address it had while in service, '
  || 'by its collector; decode and profile_mismatch are not failures; erroring at or above '
  || 'the threshold, only while in service and read by us');

SELECT pg_temp.is(
  (SELECT detail FROM health.problems WHERE kind = 'endpoint_errors' AND subject = 'sqlp_flaky'),
  '3 of 10 reads failed (30.00%) within 1 day, missed by reason {"timeout": 2, "exception": 1}, '
  || 'at 10.0.1.2:502 via sqlp_a',
  'an erroring endpoint''s problem says how many reads failed, why, and where');

SELECT pg_temp.is(
  (SELECT string_agg(subject, ', ' ORDER BY subject) FROM health.problems
   WHERE kind = 'endpoint_errors'),
  'sqlp_edge, sqlp_flaky, sqlp_moved',
  'each erroring endpoint is one problem');

SELECT pg_temp.is(pg_temp.unkeyed_scans('SELECT * FROM health.endpoints'), NULL,
  'the view reads readings and missed reads only by index lookups, never by a scan');

-- Each index lookup in the plan of q on an index over the endpoint's address,
-- by index name, and whether read_at is bounded in its index condition.
CREATE FUNCTION pg_temp.address_lookups(q text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
  plan jsonb;
BEGIN
  SET LOCAL enable_seqscan = off;
  EXECUTE 'EXPLAIN (FORMAT JSON) ' || q INTO plan;
  RESET enable_seqscan;
  RETURN (SELECT string_agg(DISTINCT format('%s %s', regexp_replace(n ->> 'Index Name',
                                                                     '^_hyper_[0-9]+_[0-9]+_chunk_', ''),
                                            (n ->> 'Index Cond' ~ 'read_at')::text), ', ')
          FROM jsonb_path_query(plan, 'lax $.**') n
          WHERE jsonb_typeof(n) = 'object' AND n ->> 'Index Name' ~ '_address_time$');
END
$$;

SELECT pg_temp.is(pg_temp.address_lookups('SELECT * FROM health.endpoints'),
  'missed_reads_address_time true, readings_address_time true',
  'readings and missed reads are looked up by address and time, read_at bounded in the index');

SELECT admin.set_health_thresholds(collector_silent_after => '1 hour',
  meter_silent_intervals => 4, backlog_near_capacity => 0.8, lookback => '3 days',
  endpoint_error_rate => 0.2);

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s', endpoint_id, error_rate), ', ' ORDER BY endpoint_id)
   FROM health.endpoints WHERE erroring AND endpoint_id LIKE 'sqlp_%'),
  'sqlp_flaky 0.3000, sqlp_steady 0.3400',
  'the lookback and error rate in force are the ones judged by');

ROLLBACK;
