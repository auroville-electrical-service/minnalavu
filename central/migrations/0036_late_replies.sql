-- migrate:up

-- Late replies (ADR 0024): per meter and UTC day, the replies that came after
-- their request had timed out or been retried, skipped as stale, as batch.v1's
-- latency carries them in `late`. A latency entry without `late` was counted
-- by a collector that does not count them: its late_data is NULL, which is
-- not zero. health.endpoint_timeouts shows them beside each endpoint's
-- answered latency and its timeout now, for setting timeouts from evidence.
-- contract: central/test/latency.sql

ALTER TABLE store.latency_days
  ADD COLUMN late_data bigint CHECK (late_data >= 0),
  ADD COLUMN late_exceptions jsonb CHECK (jsonb_typeof(late_exceptions) = 'object'),
  ADD CONSTRAINT late_counted_whole CHECK ((late_data IS NULL) = (late_exceptions IS NULL));

COMMENT ON COLUMN store.latency_days.late_data IS
  'Data replies from the unit that came too late for their request and were skipped as stale; NULL when the collector did not count late replies.';
COMMENT ON COLUMN store.latency_days.late_exceptions IS
  'Late exception replies by exception code, in decimal: {"11": 2}; a code with none is absent. NULL exactly when late_data is.';

-- As in 0018_latency.sql, with an entry's optional late counts.
-- contract: central/test/schema.sql
CREATE OR REPLACE FUNCTION store.check_latency_day(v jsonb, path text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  e record;
BEGIN
  PERFORM store.check_object(v, path, ARRAY[
    'endpoint', 'unit_id', 'date', 'poller_started_at', 'buckets_version', 'retries',
    'timeouts', 'max_ms', 'buckets'], ARRAY['late']);
  PERFORM store.check_object(v -> 'endpoint', path || '.endpoint', ARRAY['host', 'port']);
  PERFORM store.check_string(v -> 'endpoint' -> 'host', path || '.endpoint.host', 2147483647);
  PERFORM store.check_integer(v -> 'endpoint' -> 'port', path || '.endpoint.port', 1, 65535);
  PERFORM store.check_integer(v -> 'unit_id', path || '.unit_id', 1, 247);
  PERFORM store.check_date(v -> 'date', path || '.date');
  PERFORM store.check_time(v -> 'poller_started_at', path || '.poller_started_at', 6,
                           'microseconds');
  PERFORM store.check_count(v -> 'buckets_version', path || '.buckets_version', 1);
  PERFORM store.check_count(v -> f, path || '.' || f, 0)
    FROM unnest(ARRAY['retries', 'timeouts']) f;
  IF v -> 'max_ms' <> 'null'::jsonb THEN
    PERFORM store.check_count(v -> 'max_ms', path || '.max_ms', 0);
  END IF;
  PERFORM store.check_array(v -> 'buckets', path || '.buckets', 2, 2147483647);
  FOR e IN SELECT value, ordinality - 1 AS i FROM jsonb_array_elements(v -> 'buckets') WITH ORDINALITY LOOP
    PERFORM store.check_count(e.value, format('%s.buckets[%s]', path, e.i), 0);
  END LOOP;
  IF v ? 'late' THEN
    PERFORM store.check_late(v -> 'late', path || '.late');
  END IF;
END
$$;

-- contract: central/test/schema.sql
CREATE FUNCTION store.check_late(v jsonb, path text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  e record;
BEGIN
  PERFORM store.check_object(v, path, ARRAY['data', 'exceptions']);
  PERFORM store.check_count(v -> 'data', path || '.data', 0);
  IF jsonb_typeof(v -> 'exceptions') <> 'object' THEN
    PERFORM store.reject(path || '.exceptions', 'must be an object of counts by exception code');
  END IF;
  FOR e IN SELECT key, value FROM jsonb_each(v -> 'exceptions') LOOP
    IF e.key !~ '^([1-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])$' THEN
      PERFORM store.reject(path || '.exceptions',
        format('%s is not an exception code: 1 to 255, in decimal', quote_literal(left(e.key, 20))));
    END IF;
    PERFORM store.check_count(e.value, format('%s.exceptions.%s', path, e.key), 1);
  END LOOP;
END
$$;

-- As in 0018_latency.sql, with the late counts: NULL when the entry has none.
DROP FUNCTION store.batch_latency_days(jsonb);
CREATE FUNCTION store.batch_latency_days(b jsonb)
RETURNS TABLE (
  endpoint_host text, endpoint_port integer, unit_id smallint, day date,
  poller_started_at timestamptz, buckets_version bigint, retries bigint, timeouts bigint,
  max_ms bigint, buckets bigint[], late_data bigint, late_exceptions jsonb
)
LANGUAGE sql STABLE AS $$
  SELECT l -> 'endpoint' ->> 'host', (l -> 'endpoint' ->> 'port')::numeric::integer,
         (l ->> 'unit_id')::numeric::smallint, (l ->> 'date')::date,
         (l ->> 'poller_started_at')::timestamptz, (l ->> 'buckets_version')::numeric::bigint,
         (l ->> 'retries')::numeric::bigint, (l ->> 'timeouts')::numeric::bigint,
         (l ->> 'max_ms')::numeric::bigint,
         ARRAY(SELECT (n #>> '{}')::numeric::bigint
               FROM jsonb_array_elements(l -> 'buckets') WITH ORDINALITY q(n, i) ORDER BY i),
         (l -> 'late' ->> 'data')::numeric::bigint,
         CASE WHEN l ? 'late' THEN coalesce(
           (SELECT jsonb_object_agg(x.key, (x.value #>> '{}')::numeric::bigint)
            FROM jsonb_each(l -> 'late' -> 'exceptions') x),
           '{}') END
  FROM jsonb_array_elements(coalesce(b -> 'latency', '[]')) l
$$;

-- As in 0035_copy_fills.sql, keeping a latency entry's late counts, and
-- counting one that differs in them as conflicting.
-- contract: central/test/ingest.sql, central/test/latency.sql
CREATE OR REPLACE FUNCTION api.ingest(jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  b jsonb := $1;
  caller text := store.caller();
  id uuid;
  owner text;
  first_received timestamptz;
  resent boolean;
  readings_in integer;
  readings_new integer;
  readings_conflicting integer;
  missed_in integer;
  missed_new integer;
  firmware_in integer;
  firmware_new integer;
  firmware_conflicting integer;
  checks_in integer;
  checks_new integer;
  checks_conflicting integer;
  latency_in integer;
  latency_new integer;
  latency_conflicting integer;
  entries_in integer;
  entries_new integer;
  entries_conflicting integer;
  meter_clocks_in integer;
  meter_clocks_new integer;
  meter_clocks_conflicting integer;
  unknown_requests uuid[];
  fills jsonb;
BEGIN
  IF caller IS NULL THEN
    RAISE SQLSTATE 'PT403' USING MESSAGE = 'the caller is not a registered collector';
  END IF;
  PERFORM store.check_batch(b);
  PERFORM store.check_catalog(b);
  PERFORM store.check_copied_catalog(b);
  PERFORM store.check_latency(b);
  id := (b ->> 'batch_id')::uuid;
  readings_in := jsonb_array_length(b -> 'readings');
  missed_in := jsonb_array_length(b -> 'missed_reads');
  firmware_in := coalesce(jsonb_array_length(b -> 'firmware_reads'), 0);
  checks_in := coalesce(jsonb_array_length(b -> 'clock_checks'), 0);
  latency_in := coalesce(jsonb_array_length(b -> 'latency'), 0);
  entries_in := coalesce(jsonb_array_length(b -> 'stored_entries'), 0);
  meter_clocks_in := coalesce(jsonb_array_length(b -> 'meter_clock_reads'), 0);

  INSERT INTO store.batches
    (batch_id, collector_id, received_at, clock_source, clock_last_sync_at, readings, missed_reads)
  VALUES
    (id, caller, now(), (b -> 'clock' ->> 'source')::store.clock_source,
     (b -> 'clock' ->> 'last_sync_at')::timestamptz, readings_in, missed_in)
  ON CONFLICT (batch_id) DO NOTHING;
  resent := NOT FOUND;

  SELECT collector_id, received_at INTO owner, first_received
    FROM store.batches WHERE batch_id = id;
  IF owner <> caller THEN
    RAISE SQLSTATE 'PT409' USING MESSAGE = format('batch %s was sent by another collector', id);
  END IF;

  WITH inserted AS (
    INSERT INTO store.readings
      (meter_serial, register_key, read_at, value, profile, profile_version, endpoint_host,
       endpoint_port, unit_id, product_code, collector_id, batch_id)
    SELECT r.*, caller, id FROM store.batch_readings(b) r
    ON CONFLICT (meter_serial, register_key, read_at) DO NOTHING
    RETURNING 1
  )
  SELECT count(*) INTO readings_new FROM inserted;

  WITH differing AS (
    SELECT r.*
    FROM store.batch_readings(b) r
    JOIN store.readings s USING (meter_serial, register_key, read_at)
    WHERE (s.value::text, s.profile, s.profile_version, s.endpoint_host, s.endpoint_port,
           s.unit_id, s.product_code)
          IS DISTINCT FROM
          (r.value::text, r.profile, r.profile_version, r.endpoint_host, r.endpoint_port,
           r.unit_id, r.product_code)
  ), kept AS (
    INSERT INTO store.reading_conflicts
      (meter_serial, register_key, read_at, value, profile, profile_version, endpoint_host,
       endpoint_port, unit_id, product_code, collector_id, batch_id, received_at)
    SELECT d.*, caller, id, now() FROM differing d
    ON CONFLICT DO NOTHING
  )
  SELECT count(*) INTO readings_conflicting FROM differing;

  WITH inserted AS (
    INSERT INTO store.missed_reads
      (meter_serial, register_key, read_at, reason, exception_code, detail, attempts, raw_words,
       profile, profile_version, endpoint_host, endpoint_port, unit_id, collector_id, batch_id)
    SELECT m.*, caller, id FROM store.batch_missed_reads(b) m
    ON CONFLICT (collector_id, endpoint_host, endpoint_port, unit_id, register_key, read_at)
      DO NOTHING
    RETURNING 1
  )
  SELECT count(*) INTO missed_new FROM inserted;

  WITH inserted AS (
    INSERT INTO store.firmware_reads
      (meter_serial, product_code, read_at, software, firmware_1, firmware_2, modbus_version,
       endpoint_host, endpoint_port, unit_id, collector_id, batch_id)
    SELECT f.*, caller, id FROM store.batch_firmware_reads(b) f
    ON CONFLICT (collector_id, endpoint_host, endpoint_port, unit_id, read_at) DO NOTHING
    RETURNING 1
  )
  SELECT count(*) INTO firmware_new FROM inserted;

  -- Counted, not kept: names are not charged on, and the stored record stands.
  SELECT count(*) INTO firmware_conflicting
  FROM store.batch_firmware_reads(b) f
  JOIN store.firmware_reads s USING (endpoint_host, endpoint_port, unit_id, read_at)
  WHERE s.collector_id = caller
    AND (s.meter_serial, s.product_code, s.software, s.firmware_1, s.firmware_2, s.modbus_version)
        IS DISTINCT FROM
        (f.meter_serial, f.product_code, f.software, f.firmware_1, f.firmware_2, f.modbus_version);

  WITH inserted AS (
    INSERT INTO store.clock_checks
      (t1, t4, trigger, server, outcome, t2_unix, t3_unix, address, stratum, leap, reference_id,
       collector_id, batch_id)
    SELECT c.*, caller, id FROM store.batch_clock_checks(b) c
    ON CONFLICT (collector_id, t1) DO NOTHING
    RETURNING 1
  )
  SELECT count(*) INTO checks_new FROM inserted;

  -- Counted, not kept, as firmware reads: the stored check stands.
  SELECT count(*) INTO checks_conflicting
  FROM store.batch_clock_checks(b) c
  JOIN store.clock_checks s ON s.collector_id = caller AND s.t1 = c.t1
  WHERE (s.t4, s.trigger, s.server, s.outcome, s.t2_unix, s.t3_unix, s.address, s.stratum,
         s.leap, s.reference_id)
        IS DISTINCT FROM
        (c.t4, c.trigger, c.server, c.outcome, c.t2_unix, c.t3_unix, c.address, c.stratum,
         c.leap, c.reference_id);

  WITH inserted AS (
    INSERT INTO store.latency_days
      (endpoint_host, endpoint_port, unit_id, day, poller_started_at, buckets_version, retries,
       timeouts, max_ms, buckets, late_data, late_exceptions, collector_id, batch_id)
    SELECT l.*, caller, id FROM store.batch_latency_days(b) l
    ON CONFLICT (collector_id, endpoint_host, endpoint_port, unit_id, day, poller_started_at)
      DO NOTHING
    RETURNING 1
  )
  SELECT count(*) INTO latency_new FROM inserted;

  -- Counted, not kept, as clock checks: the stored entry stands.
  SELECT count(*) INTO latency_conflicting
  FROM store.batch_latency_days(b) l
  JOIN store.latency_days s
    ON (s.collector_id, s.endpoint_host, s.endpoint_port, s.unit_id, s.day, s.poller_started_at)
       = (caller, l.endpoint_host, l.endpoint_port, l.unit_id, l.day, l.poller_started_at)
  WHERE (s.buckets_version, s.retries, s.timeouts, s.max_ms, s.buckets, s.late_data,
         s.late_exceptions)
        IS DISTINCT FROM
        (l.buckets_version, l.retries, l.timeouts, l.max_ms, l.buckets, l.late_data,
         l.late_exceptions);

  WITH inserted AS (
    INSERT INTO store.stored_entries
      (meter_serial, store, register_key, meter_time, value, interval_s, profile, profile_version,
       product_code, slot, copied_at, request_id, endpoint_host, endpoint_port, unit_id,
       collector_id, batch_id)
    SELECT e.*, caller, id FROM store.batch_stored_entries(b) e
    ON CONFLICT (meter_serial, store, register_key, meter_time) DO NOTHING
    RETURNING 1
  )
  SELECT count(*) INTO entries_new FROM inserted;

  WITH differing AS (
    SELECT e.*
    FROM store.batch_stored_entries(b) e
    JOIN store.stored_entries s USING (meter_serial, store, register_key, meter_time)
    WHERE (s.value::text, s.interval_s, s.profile, s.profile_version, s.product_code)
          IS DISTINCT FROM
          (e.value::text, e.interval_s, e.profile, e.profile_version, e.product_code)
  ), kept AS (
    INSERT INTO store.stored_entry_conflicts
      (meter_serial, store, register_key, meter_time, value, interval_s, profile, profile_version,
       product_code, slot, copied_at, request_id, endpoint_host, endpoint_port, unit_id,
       collector_id, batch_id, received_at)
    SELECT d.*, caller, id, now() FROM differing d
    ON CONFLICT DO NOTHING
  )
  SELECT count(*) INTO entries_conflicting FROM differing;

  WITH inserted AS (
    INSERT INTO store.meter_clock_reads
      (endpoint_host, endpoint_port, unit_id, collector_at, meter_serial, profile,
       profile_version, meter_time, collector_id, batch_id)
    SELECT m.*, caller, id FROM store.batch_meter_clock_reads(b) m
    ON CONFLICT (collector_id, endpoint_host, endpoint_port, unit_id, collector_at) DO NOTHING
    RETURNING 1
  )
  SELECT count(*) INTO meter_clocks_new FROM inserted;

  WITH differing AS (
    SELECT m.*
    FROM store.batch_meter_clock_reads(b) m
    JOIN store.meter_clock_reads s
      ON (s.collector_id, s.endpoint_host, s.endpoint_port, s.unit_id, s.collector_at)
         = (caller, m.endpoint_host, m.endpoint_port, m.unit_id, m.collector_at)
    WHERE (s.meter_serial, s.profile, s.profile_version, s.meter_time)
          IS DISTINCT FROM (m.meter_serial, m.profile, m.profile_version, m.meter_time)
  ), kept AS (
    INSERT INTO store.meter_clock_read_conflicts
      (endpoint_host, endpoint_port, unit_id, collector_at, meter_serial, profile,
       profile_version, meter_time, collector_id, batch_id, received_at)
    SELECT d.*, caller, id, now() FROM differing d
    ON CONFLICT DO NOTHING
  )
  SELECT count(*) INTO meter_clocks_conflicting FROM differing;

  unknown_requests := jobs.link_batch(b, caller, id);
  fills := jobs.link_fills(b, caller, id);

  INSERT INTO store.uploads
    (batch_id, collector_id, received_at, sent_at, backlog_events, backlog_bytes,
     backlog_batches, backlog_oldest, backlog_max_bytes, backlog_refused,
     backlog_discarded_files, backlog_quarantined, readings_inserted, readings_duplicate,
     readings_conflicting, missed_reads_inserted, missed_reads_duplicate, config_digest,
     config_refused_digest, config_refusal_reason, stored_entries_inserted,
     stored_entries_duplicate, stored_entries_conflicting, meter_clock_reads_inserted,
     meter_clock_reads_duplicate, meter_clock_reads_conflicting)
  SELECT id, caller, now(), (b ->> 'sent_at')::timestamptz,
         (k ->> 'events')::numeric, (k ->> 'bytes')::numeric, (k ->> 'batches')::numeric,
         (k ->> 'oldest')::timestamptz, (k ->> 'max_bytes')::numeric,
         (k ->> 'refused')::numeric, (k ->> 'discarded_files')::numeric,
         (k ->> 'quarantined')::numeric,
         readings_new, readings_in - readings_new - readings_conflicting, readings_conflicting,
         missed_new, missed_in - missed_new,
         k -> 'config' ->> 'digest', k -> 'config' ->> 'refused_digest',
         k -> 'config' ->> 'reason',
         entries_new, entries_in - entries_new - entries_conflicting, entries_conflicting,
         meter_clocks_new, meter_clocks_in - meter_clocks_new - meter_clocks_conflicting,
         meter_clocks_conflicting
  FROM (SELECT b -> 'backlog' AS k) backlog;

  -- jobs and unknown_requests are left out when there are none.
  RETURN jsonb_build_object(
    'batch_id', id,
    'resent', resent,
    'first_received_at', first_received,
    'config_digest', registry.config_digest(registry.collector_config(caller)),
    'readings', jsonb_build_object(
      'received', readings_in,
      'inserted', readings_new,
      'duplicate', readings_in - readings_new - readings_conflicting,
      'conflicting', readings_conflicting),
    'missed_reads', jsonb_build_object(
      'received', missed_in,
      'inserted', missed_new,
      'duplicate', missed_in - missed_new),
    'firmware_reads', jsonb_build_object(
      'received', firmware_in,
      'inserted', firmware_new,
      'duplicate', firmware_in - firmware_new - firmware_conflicting,
      'conflicting', firmware_conflicting),
    'clock_checks', jsonb_build_object(
      'received', checks_in,
      'inserted', checks_new,
      'duplicate', checks_in - checks_new - checks_conflicting,
      'conflicting', checks_conflicting),
    'latency', jsonb_build_object(
      'received', latency_in,
      'inserted', latency_new,
      'duplicate', latency_in - latency_new - latency_conflicting,
      'conflicting', latency_conflicting),
    'stored_entries', jsonb_build_object(
      'received', entries_in,
      'inserted', entries_new,
      'duplicate', entries_in - entries_new - entries_conflicting,
      'conflicting', entries_conflicting),
    'meter_clock_reads', jsonb_build_object(
      'received', meter_clocks_in,
      'inserted', meter_clocks_new,
      'duplicate', meter_clocks_in - meter_clocks_new - meter_clocks_conflicting,
      'conflicting', meter_clocks_conflicting),
    'fill_results', fills)
    || jsonb_strip_nulls(jsonb_build_object(
         'jobs', jobs.pending(caller),
         'unknown_requests', to_jsonb(unknown_requests)));
END
$$;

-- Per registered endpoint, as health.endpoint_latency gives it a row per UTC
-- day of the lookback and bucket version: its timeout now, what answered
-- (answered, retries, timeouts, p99, max), and the late replies its meters'
-- entries counted: late_entries of entries counted them, and late_data and
-- late_exceptions sum those; both NULL when none did.
-- contract: central/test/latency.sql
CREATE VIEW health.endpoint_timeouts AS
  WITH since AS (
    SELECT ((now() - lookback) AT TIME ZONE 'UTC')::date AS day FROM health.thresholds
  ), days AS (
    SELECT d.collector_id, d.endpoint_host, d.endpoint_port, d.day, d.buckets_version,
           count(d.late_data) AS late_entries, sum(d.late_data)::bigint AS late_data
    FROM store.latency_days d
    WHERE d.day >= (SELECT day FROM since)
    GROUP BY d.collector_id, d.endpoint_host, d.endpoint_port, d.day, d.buckets_version
  ), codes AS (
    SELECT d.collector_id, d.endpoint_host, d.endpoint_port, d.day, d.buckets_version,
           x.key AS code, sum((x.value #>> '{}')::bigint) AS n
    FROM store.latency_days d
    CROSS JOIN LATERAL jsonb_each(d.late_exceptions) x
    WHERE d.day >= (SELECT day FROM since)
    GROUP BY d.collector_id, d.endpoint_host, d.endpoint_port, d.day, d.buckets_version, x.key
  )
  SELECT l.endpoint_id, l.collector_id, l.host, l.port, l.day, l.buckets_version, now.timeout_ms,
         l.entries, l.answered, l.retries, l.timeouts, l.p99_ms, l.max_ms, k.late_entries,
         CASE WHEN k.late_entries > 0 THEN k.late_data END AS late_data,
         CASE WHEN k.late_entries > 0 THEN coalesce(
           (SELECT jsonb_object_agg(c.code, c.n)
            FROM codes c
            WHERE (c.collector_id, c.endpoint_host, c.endpoint_port, c.day, c.buckets_version)
                  = (l.collector_id, l.host, l.port, l.day, l.buckets_version)),
           '{}') END AS late_exceptions
  FROM health.endpoint_latency l
  JOIN registry.endpoint_history now ON now.endpoint_id = l.endpoint_id AND now.period @> now()
  JOIN days k
    ON (k.collector_id, k.endpoint_host, k.endpoint_port, k.day, k.buckets_version)
       = (l.collector_id, l.host, l.port, l.day, l.buckets_version);

GRANT SELECT ON health.endpoint_timeouts TO monitor;

-- migrate:down
-- Forward only: undo with a new migration.
