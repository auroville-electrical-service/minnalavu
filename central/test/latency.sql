-- Request latency: the bucket versions loaded from contract/latency, what
-- ingest stores of batch.v1's latency and what it refuses, never twice, and
-- the percentile views, merged across entries of one bucket version.

\ir lib/assert.sql
\set basic `cat ../contract/fixtures/batch.v1.basic.json`
\set buckets1 `cat ../contract/latency/buckets.v1.json`

BEGIN;

SELECT admin.create_collector('sqltest_lat_a');
SELECT admin.create_collector('sqltest_lat_b');

-- Bucket versions.

SELECT pg_temp.is(admin.load_latency_buckets(:'buckets1'), 'already loaded',
  'bin/test loaded version 1 from contract/latency, and loading it again changes nothing');

SELECT pg_temp.is(
  (SELECT cardinality(bounds_ms) || ' ' || bounds_ms[1] || ' ' || bounds_ms[43]
   FROM store.latency_bucket_versions WHERE version = 1),
  '43 1 60000',
  'version 1 holds its 43 bounds, 1 ms to 60000 ms');

SELECT pg_temp.is(
  pg_temp.sqlstate_as('postgres', format('SELECT admin.load_latency_buckets(%L)', d)),
  '22023', 'the loader refuses ' || left(d, 60))
FROM unnest(ARRAY[
  jsonb_set(:'buckets1', '{bounds_ms,0}', '2')::text,
  '{"version": 9, "bounds_ms": []}',
  '{"version": 9, "bounds_ms": [1, 3, 3]}',
  '{"version": 9, "bounds_ms": [0, 3]}',
  '{"version": 9, "bounds_ms": [1, 2.5]}',
  '{"version": 9, "bounds_ms": "1"}',
  '{"version": 0, "bounds_ms": [1]}',
  '{"version": 1.5, "bounds_ms": [1]}',
  '{"bounds_ms": [1]}'
]) d;

SELECT pg_temp.is(admin.load_latency_buckets('{"version": 2, "bounds_ms": [10, 100]}'), 'new',
  'a new version is loaded as new');

SELECT pg_temp.is(pg_temp.sqlstate_as('postgres', q), 'P0001', 'the owner is refused: ' || q)
FROM unnest(ARRAY[
  $q$UPDATE store.latency_bucket_versions SET bounds_ms = '{1}'$q$,
  'DELETE FROM store.latency_bucket_versions',
  'TRUNCATE store.latency_bucket_versions, store.latency_days'
]) q;

-- Ingest. Unit 1's day in two entries, before and after a restart, and unit
-- 3's. Unit 1: answers up to 12 ms (3, in the second entry), 20 (5), 25 (90),
-- 30 (4) and 40 (1, the max, 37 ms); unit 3: one above 60000.
CREATE TEMP TABLE basic (batch jsonb);
INSERT INTO basic VALUES (:'basic');

-- 44 counts, version 1's: count at each bucket index (from 0) given in pairs.
CREATE FUNCTION pg_temp.buckets(VARIADIC pairs integer[]) RETURNS jsonb
LANGUAGE sql AS $$
  SELECT jsonb_agg(coalesce((SELECT pairs[2 * j] FROM generate_series(1, cardinality(pairs) / 2) j
                             WHERE pairs[2 * j - 1] = i), 0) ORDER BY i)
  FROM generate_series(0, 43) i
$$;

CREATE FUNCTION pg_temp.entry(unit integer, started text, retries integer, timeouts integer,
                              max_ms integer, buckets jsonb, day text DEFAULT '2026-11-01')
RETURNS jsonb
LANGUAGE sql AS $$
  SELECT jsonb_build_object('endpoint', '{"host": "10.0.0.21", "port": 502}'::jsonb,
    'unit_id', unit, 'date', day, 'poller_started_at', started, 'buckets_version', 1,
    'retries', retries, 'timeouts', timeouts, 'max_ms', max_ms, 'buckets', buckets)
$$;

CREATE FUNCTION pg_temp.with_latency(id text, entries jsonb) RETURNS jsonb
LANGUAGE sql AS $$
  SELECT jsonb_set(jsonb_set(batch, '{batch_id}', to_jsonb(id)), '{latency}', entries) FROM basic
$$;

CREATE TEMP TABLE day_entries (entries jsonb);
INSERT INTO day_entries SELECT jsonb_build_array(
  pg_temp.entry(1, '2026-10-30T06:12:44.123456Z', 2, 1, 37, pg_temp.buckets(10, 5, 11, 90, 12, 4, 13, 1)),
  pg_temp.entry(1, '2026-11-01T13:02:09.5Z', 0, 0, 12, pg_temp.buckets(8, 3)),
  pg_temp.entry(3, '2026-11-02T05:00:00+05:30', 0, 4, 61000, pg_temp.buckets(43, 1)));

CREATE FUNCTION pg_temp.day_batch(id text) RETURNS jsonb
LANGUAGE sql AS $$
  SELECT pg_temp.with_latency(id, entries) FROM day_entries
$$;

SELECT pg_temp.is(
  pg_temp.ingest_as('collector_sqltest_lat_a', pg_temp.day_batch('d1d1d1d1-d1d1-4d1d-8d1d-d1d1d1d1d1d1'))
    -> 'latency',
  '{"received": 3, "inserted": 3, "duplicate": 0, "conflicting": 0}',
  'a batch''s latency entries are stored, and the answer counts them');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s:%s %s %s %s v%s %s %s %s %s', collector_id, endpoint_host,
                            endpoint_port, unit_id, day, poller_started_at, buckets_version,
                            retries, timeouts, coalesce(max_ms::text, '-'),
                            (SELECT string_agg(format('%s:%s', i - 1, n), ' ' ORDER BY i)
                             FROM unnest(buckets) WITH ORDINALITY u(n, i) WHERE n > 0)),
                     '; ' ORDER BY unit_id, poller_started_at)
   FROM store.latency_days WHERE collector_id = 'sqltest_lat_a'),
  'sqltest_lat_a 10.0.0.21:502 1 2026-11-01 2026-10-30 06:12:44.123456+00 v1 2 1 37 10:5 11:90 12:4 13:1; '
  || 'sqltest_lat_a 10.0.0.21:502 1 2026-11-01 2026-11-01 13:02:09.5+00 v1 0 0 12 8:3; '
  || 'sqltest_lat_a 10.0.0.21:502 3 2026-11-01 2026-11-01 23:30:00+00 v1 0 4 61000 43:1',
  'each entry is stored as sent: its key, version, retries, timeouts, exact max and every bucket');

SELECT pg_temp.is(
  (SELECT min(cardinality(buckets)) || ' ' || max(cardinality(buckets)) FROM store.latency_days),
  '44 44', 'every bucket is kept, the empty ones too');

SELECT pg_temp.is(
  pg_temp.ingest_as('collector_sqltest_lat_a', pg_temp.day_batch('d1d1d1d1-d1d1-4d1d-8d1d-d1d1d1d1d1d1'))
    -> 'latency',
  '{"received": 3, "inserted": 0, "duplicate": 3, "conflicting": 0}',
  'a resent batch''s latency entries are not stored twice');

SELECT pg_temp.is(
  pg_temp.ingest_as('collector_sqltest_lat_a', pg_temp.day_batch('d2d2d2d2-d2d2-4d2d-8d2d-d2d2d2d2d2d2'))
    -> 'latency',
  '{"received": 3, "inserted": 0, "duplicate": 3, "conflicting": 0}',
  'an entry already stored is not stored again from another batch: the key is its collector, '
  || 'endpoint, unit, date and poller start');

SELECT pg_temp.is(
  pg_temp.ingest_as('collector_sqltest_lat_a',
    pg_temp.changed(pg_temp.day_batch('d3d3d3d3-d3d3-4d3d-8d3d-d3d3d3d3d3d3'),
                    '{"path": ["latency", 0, "max_ms"], "value": 38}'))
    -> 'latency',
  '{"received": 3, "inserted": 0, "duplicate": 2, "conflicting": 1}',
  'an entry that differs from the stored one at its key is conflicting');

SELECT pg_temp.is(
  (SELECT string_agg(max_ms::text, ' ' ORDER BY unit_id, poller_started_at)
   FROM store.latency_days WHERE collector_id = 'sqltest_lat_a'),
  '37 12 61000',
  'and the stored entry is unchanged');

SELECT pg_temp.is(
  pg_temp.ingest_as('collector_sqltest_lat_b', pg_temp.day_batch('d4d4d4d4-d4d4-4d4d-8d4d-d4d4d4d4d4d4'))
    -> 'latency',
  '{"received": 3, "inserted": 3, "duplicate": 0, "conflicting": 0}',
  'the same key from another collector is another entry');

-- What ingest refuses beyond the schema: the entry against its bucket
-- version and itself.
SELECT pg_temp.is(
  pg_temp.ingest_error('collector_sqltest_lat_a', pg_temp.with_latency(
    'e1e1e1e1-e1e1-4e1e-8e1e-e1e1e1e1e1e1', jsonb_build_array(e))),
  want, 'refused: ' || why)
FROM (VALUES
  (pg_temp.entry(1, '2026-11-01T00:00:00Z', 0, 0, 37, pg_temp.buckets(13, 1) - 43),
   'PT422: batch rejected: batch.latency[0].buckets must have 44 counts, one per bound of latency buckets version 1 and one above the last',
   'buckets one short of its version''s'),
  (pg_temp.entry(1, '2026-11-01T00:00:00Z', 0, 0, 37, pg_temp.buckets(13, 1) || '[0]'),
   'PT422: batch rejected: batch.latency[0].buckets must have 44 counts, one per bound of latency buckets version 1 and one above the last',
   'buckets one over its version''s'),
  (pg_temp.entry(1, '2026-11-01T00:00:00Z', 2, 0, 37, pg_temp.buckets(13, 1)),
   'PT422: batch rejected: batch.latency[0].retries must be at most the answers, the sum of buckets',
   'more retries than answers'),
  (pg_temp.entry(1, '2026-11-01T00:00:00Z', 0, 3, 37, pg_temp.buckets(0, 0)),
   'PT422: batch rejected: batch.latency[0].max_ms must be null when nothing answered',
   'a max with no answers'),
  (pg_temp.entry(1, '2026-11-01T00:00:00Z', 0, 0, NULL, pg_temp.buckets(13, 1)),
   'PT422: batch rejected: batch.latency[0].max_ms must be given when something answered',
   'no max with answers'),
  (pg_temp.entry(1, '2026-11-01T00:00:00Z', 0, 0, 41, pg_temp.buckets(12, 3, 13, 1)),
   'PT422: batch rejected: batch.latency[0].max_ms must be in the last bucket that counts an answer: above 30 ms and at most 40 ms',
   'a max above its last bucket'),
  (pg_temp.entry(1, '2026-11-01T00:00:00Z', 0, 0, 30, pg_temp.buckets(12, 3, 13, 1)),
   'PT422: batch rejected: batch.latency[0].max_ms must be in the last bucket that counts an answer: above 30 ms and at most 40 ms',
   'a max below its last bucket'),
  (pg_temp.entry(1, '2026-11-01T00:00:00Z', 0, 0, 2, pg_temp.buckets(0, 1)),
   'PT422: batch rejected: batch.latency[0].max_ms must be in the last bucket that counts an answer: at most 1 ms',
   'a max above the first bucket, its only one'),
  (pg_temp.entry(1, '2026-11-01T00:00:00Z', 0, 0, 60000, pg_temp.buckets(43, 1)),
   'PT422: batch rejected: batch.latency[0].max_ms must be in the last bucket that counts an answer: above 60000 ms',
   'a max not above the last bound with an answer counted above it'),
  (pg_temp.entry(1, '2026-11-02T00:00:00Z', 0, 0, 37, pg_temp.buckets(13, 1)),
   'PT422: batch rejected: batch.latency[0].poller_started_at must be before its date ended (UTC)',
   'a poller that started after its date ended'),
  (pg_temp.entry(1, '2026-11-02T05:30:00+05:30', 0, 0, 37, pg_temp.buckets(13, 1)),
   'PT422: batch rejected: batch.latency[0].poller_started_at must be before its date ended (UTC)',
   'the same, with an offset'),
  (jsonb_set(pg_temp.entry(1, '2026-11-01T00:00:00Z', 0, 0, 37, pg_temp.buckets(13, 1)),
             '{buckets_version}', '7'),
   'PT503: batch.latency[0]: latency buckets version 7 is not loaded in the store',
   'a bucket version not loaded, with 503, so the collector keeps the batch')
) cases (e, want, why);

SELECT pg_temp.is(
  pg_temp.ingest_error('collector_sqltest_lat_a', pg_temp.with_latency(
    'e2e2e2e2-e2e2-4e2e-8e2e-e2e2e2e2e2e2', jsonb_build_array(
      pg_temp.entry(1, '2026-11-05T00:00:00Z', 0, 0, 0, pg_temp.buckets(0, 2), '2026-11-05'),
      pg_temp.entry(3, '2026-11-05T00:00:00Z', 1, 0, 60001, pg_temp.buckets(42, 1, 43, 1),
                    '2026-11-05'),
      pg_temp.entry(9, '2026-11-05T23:59:59.999999Z', 0, 0, 1, pg_temp.buckets(0, 1),
                    '2026-11-05')))),
  'ok',
  'accepted: a max of 0 ms in the first bucket, one just above the last bound, and a poller '
  || 'started in the date''s last microsecond');

SELECT pg_temp.is(
  pg_temp.ingest_as('collector_sqltest_lat_a',
    jsonb_set(pg_temp.with_latency('e3e3e3e3-e3e3-4e3e-8e3e-e3e3e3e3e3e3', jsonb_build_array(
      jsonb_set(pg_temp.entry(1, '2026-11-01T18:00:00Z', 1, 0, 50, '[1, 4, 0]'),
                '{buckets_version}', '2'))), '{readings}', '[]'))
    -> 'latency',
  '{"received": 1, "inserted": 1, "duplicate": 0, "conflicting": 0}',
  'an entry under another loaded version is checked against its own bounds');

SELECT pg_temp.is(pg_temp.sqlstate_as('postgres', q), '23514', 'the store refuses ' || why)
FROM (VALUES
  ($q$INSERT INTO store.latency_days SELECT collector_id, endpoint_host, endpoint_port, unit_id,
       day + 10, poller_started_at, buckets_version, retries, timeouts, max_ms, '{-1,0}', batch_id
     FROM store.latency_days LIMIT 1$q$, 'a negative bucket count'),
  ($q$INSERT INTO store.latency_days SELECT collector_id, endpoint_host, endpoint_port, unit_id,
       day + 10, poller_started_at, buckets_version, -1, timeouts, max_ms, buckets, batch_id
     FROM store.latency_days LIMIT 1$q$, 'a negative retry count')
) cases (q, why);

SELECT pg_temp.is(pg_temp.sqlstate_as('postgres', q), 'P0001', 'the owner is refused: ' || q)
FROM unnest(ARRAY[
  'UPDATE store.latency_days SET retries = 0',
  'DELETE FROM store.latency_days',
  'TRUNCATE store.latency_days'
]) q;

-- Percentiles. Unit 1's day merged across its two entries: 103 answers. p50
-- (rank 52) and p90 (rank 93) fall in the 25 ms bucket, p99 (rank 102) in
-- the 30 ms one; the max is 37. Unit 3: its one answer is above the last
-- bound, so every percentile is its exact max. Version 2's entry is its own row.
SELECT pg_temp.is(
  (SELECT string_agg(format('%s v%s: %s entries, %s answered (%s on a retry), %s timed out; '
                            || 'p50 %s, p90 %s, p99 %s, max %s', unit_id, buckets_version,
                            entries, answered, retries, timeouts, p50_ms, p90_ms, p99_ms, max_ms),
                     '; ' ORDER BY buckets_version, unit_id)
   FROM store.latency_meter_days WHERE collector_id = 'sqltest_lat_a' AND day = '2026-11-01'),
  '1 v1: 2 entries, 103 answered (2 on a retry), 1 timed out; p50 25, p90 25, p99 30, max 37; '
  || '3 v1: 1 entries, 1 answered (0 on a retry), 4 timed out; p50 61000, p90 61000, p99 61000, max 61000; '
  || '1 v2: 1 entries, 5 answered (1 on a retry), 0 timed out; p50 50, p90 50, p99 50, max 50',
  'per meter and day, entries merged within a bucket version; a percentile is its bucket''s '
  || 'upper bound, never above the max');

-- Nearest rank at each edge, as alavi's Latency reads it (its test
-- "summary/1, nearest rank at each edge" counts the same answers): of 100
-- answers, the 50th is the last at most 2 ms, the 90th at most 3, the 99th at
-- most 4; the max is 5.
SELECT pg_temp.is(
  pg_temp.ingest_as('collector_sqltest_lat_a', pg_temp.with_latency(
    'f1f1f1f1-f1f1-4f1f-8f1f-f1f1f1f1f1f1', jsonb_build_array(
      pg_temp.entry(5, '2026-11-03T00:00:00Z', 0, 0, 5,
                    pg_temp.buckets(0, 49, 1, 1, 2, 40, 3, 9, 4, 1), '2026-11-03'))))
    -> 'latency' -> 'inserted',
  '1', 'an entry with answers at each percentile''s edge is stored');

SELECT pg_temp.is(
  (SELECT format('p50 %s, p90 %s, p99 %s, max %s', p50_ms, p90_ms, p99_ms, max_ms)
   FROM store.latency_meter_days WHERE collector_id = 'sqltest_lat_a' AND unit_id = 5),
  'p50 2, p90 3, p99 4, max 5',
  'each percentile is the smallest bucket holding at least p % of the answers');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s:%s v%s: %s meters, %s entries, %s answered, %s timed out; '
                            || 'p50 %s, p90 %s, p99 %s, max %s', endpoint_host, endpoint_port,
                            buckets_version, meters, entries, answered, timeouts, p50_ms, p90_ms,
                            p99_ms, max_ms), '; ' ORDER BY buckets_version)
   FROM store.latency_endpoint_days WHERE collector_id = 'sqltest_lat_a' AND day = '2026-11-01'),
  '10.0.0.21:502 v1: 2 meters, 3 entries, 104 answered, 5 timed out; p50 25, p90 25, p99 40, max 61000; '
  || '10.0.0.21:502 v2: 1 meters, 1 entries, 5 answered, 0 timed out; p50 50, p90 50, p99 50, max 50',
  'per endpoint and day, every meter''s entries merged within a bucket version');

SELECT pg_temp.is(
  (SELECT format('%s answered, %s timed out; p50 %s, max %s', answered, timeouts,
                 coalesce(p50_ms::text, 'none'), coalesce(max_ms::text, 'none'))
   FROM store.latency_meter_days WHERE collector_id = 'sqltest_lat_a' AND unit_id = 7),
  NULL, 'no row for a meter with no entry');

INSERT INTO store.latency_days
  SELECT 'sqltest_lat_a', '10.0.0.21', 502, 7, '2026-11-01', now(), 1, 0, 6, NULL,
         array_fill(0::bigint, ARRAY[44]), batch_id
  FROM store.batches WHERE collector_id = 'sqltest_lat_a' LIMIT 1;

SELECT pg_temp.is(
  (SELECT format('%s answered, %s timed out; p50 %s, p99 %s, max %s', answered, timeouts,
                 coalesce(p50_ms::text, 'none'), coalesce(p99_ms::text, 'none'),
                 coalesce(max_ms::text, 'none'))
   FROM store.latency_meter_days WHERE collector_id = 'sqltest_lat_a' AND unit_id = 7),
  '0 answered, 6 timed out; p50 none, p99 none, max none',
  'a meter that only timed out has no percentiles and no max');

-- Health: per registered endpoint, its days within the lookback, at the
-- addresses it had while in service. Rows inserted directly, dated relative
-- to now().
SELECT admin.set_health_thresholds(collector_silent_after => '1 hour',
  meter_silent_intervals => 4, backlog_near_capacity => 0.8, lookback => '1 day',
  endpoint_error_rate => 0.1, snapshot_missed_margin => '1 hour',
  history_behind_after => '62 days', snapshot_behind_after_elite_500 => '14 days',
  load_survey_behind_after_elite_440 => '7 days', load_survey_behind_after_elite_500 => '30 days');

CREATE FUNCTION pg_temp.endpoint(id text, host text, valid_from timestamptz, interval_ms integer)
RETURNS bigint
LANGUAGE sql AS $$
  SELECT admin.register_endpoint(
    endpoint_id => id, valid_from => valid_from, collector_id => 'sqltest_lat_b',
    host => host, port => 502, framing => 'tcp', polled_by_other_system => false,
    timeout_ms => 1000, max_timeouts => 3, retries => 2, busy_backoff_ms => 500,
    reconnect_backoff_min_ms => 1000, reconnect_backoff_max_ms => 60000, interval_ms => interval_ms)
$$;

-- An endpoint whose interval changed an hour ago: two periods at one address.
SELECT pg_temp.endpoint('sqllat_chain', '10.0.9.1', now() - interval '5 days', 900000);
SELECT admin.change_endpoint(
  endpoint_id => 'sqllat_chain', valid_from => now() - interval '1 hour',
  collector_id => 'sqltest_lat_b', host => '10.0.9.1', port => 502, framing => 'tcp',
  polled_by_other_system => false, timeout_ms => 1000, max_timeouts => 3, retries => 2,
  busy_backoff_ms => 500, reconnect_backoff_min_ms => 1000, reconnect_backoff_max_ms => 60000,
  interval_ms => 600000, copy => false);

CREATE FUNCTION pg_temp.latency_on(host text, unit integer, days_ago integer, ms integer)
RETURNS void
LANGUAGE sql AS $$
  INSERT INTO store.latency_days
    SELECT 'sqltest_lat_b', host, 502, unit, (now() AT TIME ZONE 'UTC')::date - days_ago,
           ((now() AT TIME ZONE 'UTC')::date - days_ago - 1)::timestamp AT TIME ZONE 'UTC', 1,
           0, 0, ms, (SELECT array_agg(CASE WHEN i = 13 THEN 2 ELSE 0 END::bigint ORDER BY i)
                      FROM generate_series(0, 43) i), batch_id
    FROM store.batches WHERE collector_id = 'sqltest_lat_b' LIMIT 1
$$;

SELECT pg_temp.latency_on('10.0.9.1', 1, 0, 33);
SELECT pg_temp.latency_on('10.0.9.1', 2, 0, 39);
SELECT pg_temp.latency_on('10.0.9.1', 1, 1, 35);
SELECT pg_temp.latency_on('10.0.9.1', 1, 3, 38);
SELECT pg_temp.latency_on('10.0.9.2', 1, 0, 31);
-- An endpoint that took its address at today's UTC midnight, within the
-- lookback: the day before at that address is not its.
SELECT pg_temp.endpoint('sqllat_new', '10.0.9.3',
                        date_trunc('day', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC', 900000);
SELECT pg_temp.latency_on('10.0.9.3', 1, 0, 34);
SELECT pg_temp.latency_on('10.0.9.3', 1, 1, 36);

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s:%s day -%s v%s: %s meters, %s answered; p50 %s, p99 %s, max %s',
                            endpoint_id, host, port, (now() AT TIME ZONE 'UTC')::date - day,
                            buckets_version, meters, answered, p50_ms, p99_ms, max_ms),
                     '; ' ORDER BY day DESC)
   FROM health.endpoint_latency WHERE endpoint_id = 'sqllat_chain'),
  'sqllat_chain 10.0.9.1:502 day -0 v1: 2 meters, 4 answered; p50 39, p99 39, max 39; '
  || 'sqllat_chain 10.0.9.1:502 day -1 v1: 1 meters, 2 answered; p50 35, p99 35, max 35',
  'an endpoint''s days within the lookback, once each though its address spans two periods; '
  || 'days before it, and an unregistered address, are left out');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s day -%s: max %s', endpoint_id,
                            (now() AT TIME ZONE 'UTC')::date - day, max_ms), '; ')
   FROM health.endpoint_latency WHERE endpoint_id = 'sqllat_new'),
  'sqllat_new day -0: max 34',
  'a day within the lookback but before the endpoint had its address is not its');

-- Found by index on the day, from the lookback's days only.
CREATE FUNCTION pg_temp.day_lookups(q text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
  plan jsonb;
BEGIN
  SET LOCAL enable_seqscan = off;
  EXECUTE 'EXPLAIN (FORMAT JSON) ' || q INTO plan;
  RESET enable_seqscan;
  RETURN (SELECT string_agg(DISTINCT format('%s %s %s', n ->> 'Node Type', n ->> 'Index Name',
                                            (n ->> 'Index Cond' ~ 'day')::text), ', ')
          FROM jsonb_path_query(plan, 'lax $.**') n
          WHERE jsonb_typeof(n) = 'object' AND n ->> 'Relation Name' = 'latency_days');
END
$$;

SELECT pg_temp.is(pg_temp.day_lookups('SELECT * FROM health.endpoint_latency'),
  'Index Scan latency_days_day true',
  'health reads only the lookback''s latency days, the day bounded in the index');

SELECT pg_temp.is(pg_temp.sqlstate_as('monitor', 'SELECT * FROM health.endpoint_latency'),
  '00000', 'monitor may read health.endpoint_latency');

ROLLBACK;
