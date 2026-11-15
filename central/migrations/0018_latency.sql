-- migrate:up

-- Each meter's request latency per UTC day, as batch.v1's latency carries it:
-- one entry per meter, day and poller start, counts only (retries, timeouts,
-- the exact max and every bucket's answers). Percentiles are views, merged
-- across entries counted under the same bucket version.

-- contract: central/test/latency.sql
CREATE TABLE store.latency_bucket_versions (
  version bigint PRIMARY KEY CHECK (version BETWEEN 1 AND 9007199254740991),
  bounds_ms integer[] NOT NULL CHECK (array_ndims(bounds_ms) = 1 AND cardinality(bounds_ms) >= 1),
  loaded_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE store.latency_bucket_versions IS
  'Each version of contract/latency''s bucket bounds, loaded by bin/load-profiles. A version never changes; a change is a new version.';
COMMENT ON COLUMN store.latency_bucket_versions.bounds_ms IS
  'Upper bounds in ms, increasing: bucket i (from 1) counts answers of at most bounds_ms[i] and more than bounds_ms[i - 1]; bucket cardinality + 1 counts answers above the last.';

-- contract: central/test/ingest.sql, central/test/latency.sql
CREATE TABLE store.latency_days (
  collector_id text NOT NULL REFERENCES store.collectors (id),
  endpoint_host text NOT NULL,
  endpoint_port integer NOT NULL,
  unit_id smallint NOT NULL,
  day date NOT NULL,
  poller_started_at timestamptz NOT NULL,
  buckets_version bigint NOT NULL REFERENCES store.latency_bucket_versions (version),
  retries bigint NOT NULL CHECK (retries >= 0),
  timeouts bigint NOT NULL CHECK (timeouts >= 0),
  max_ms bigint CHECK (max_ms >= 0),
  buckets bigint[] NOT NULL CHECK (array_ndims(buckets) = 1 AND 0 <= ALL (buckets)),
  batch_id uuid NOT NULL REFERENCES store.batches (batch_id),
  PRIMARY KEY (collector_id, endpoint_host, endpoint_port, unit_id, day, poller_started_at)
);
COMMENT ON COLUMN store.latency_days.day IS
  'batch.v1''s date: the UTC date the requests were made on, by the collector''s clock.';
COMMENT ON COLUMN store.latency_days.poller_started_at IS
  'When the poller that counted them started, by the collector''s clock: a restart''s part of a day is a row of its own.';
COMMENT ON COLUMN store.latency_days.buckets IS
  'The answers in each bucket of buckets_version''s bounds, in order, every bucket given; the answers are their sum.';
-- For the health view's days within the lookback.
CREATE INDEX latency_days_day ON store.latency_days (day);

DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['latency_bucket_versions', 'latency_days'] LOOP
    EXECUTE format(
      'CREATE TRIGGER refuse_change BEFORE UPDATE OR DELETE ON store.%I
         FOR EACH ROW EXECUTE FUNCTION store.refuse_change()', t);
    EXECUTE format(
      'CREATE TRIGGER refuse_truncate BEFORE TRUNCATE ON store.%I
         FOR EACH STATEMENT EXECUTE FUNCTION store.refuse_change()', t);
  END LOOP;
END
$$;

-- Load one contract/latency file's version, as the owner. A version already
-- loaded is left as it is when the file gives the same bounds, and refused
-- (22023) otherwise. Returns 'new' or 'already loaded'. Run by
-- bin/load-profiles.
-- contract: central/test/latency.sql
CREATE FUNCTION admin.load_latency_buckets(document jsonb) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
  v bigint;
  bounds integer[];
  loaded integer[];
BEGIN
  IF jsonb_typeof(document -> 'version') IS DISTINCT FROM 'number'
     OR (document -> 'version')::numeric <> trunc((document -> 'version')::numeric)
     OR (document -> 'version')::numeric < 1 THEN
    RAISE SQLSTATE '22023' USING MESSAGE = 'latency buckets: version must be a positive integer';
  END IF;
  v := (document -> 'version')::numeric;
  IF jsonb_typeof(document -> 'bounds_ms') IS DISTINCT FROM 'array'
     OR jsonb_array_length(document -> 'bounds_ms') = 0
     OR EXISTS (
       SELECT FROM jsonb_array_elements(document -> 'bounds_ms') WITH ORDINALITY b(x, i)
       WHERE jsonb_typeof(b.x) IS DISTINCT FROM 'number'
          OR b.x::numeric <> trunc(b.x::numeric) OR b.x::numeric < 1
          OR b.x::numeric > 2147483647
          OR b.x::numeric <= (document -> 'bounds_ms' -> (b.i::integer - 2))::numeric
             AND b.i > 1) THEN
    RAISE SQLSTATE '22023' USING MESSAGE = format(
      'latency buckets version %s: bounds_ms must be a non-empty list of increasing positive integers', v);
  END IF;
  bounds := ARRAY(SELECT x::numeric::integer
                  FROM jsonb_array_elements(document -> 'bounds_ms') WITH ORDINALITY b(x, i)
                  ORDER BY i);

  SELECT bounds_ms INTO loaded FROM store.latency_bucket_versions WHERE version = v;
  IF NOT FOUND THEN
    INSERT INTO store.latency_bucket_versions (version, bounds_ms) VALUES (v, bounds);
    RETURN 'new';
  END IF;
  IF loaded IS DISTINCT FROM bounds THEN
    RAISE SQLSTATE '22023' USING MESSAGE = format(
      'latency buckets version %s is loaded with other bounds; a change is a new version', v);
  END IF;
  RETURN 'already loaded';
END
$$;

-- JSON Schema's "date", as batch.v1 writes it: YYYY-MM-DD, a day that exists.
CREATE FUNCTION store.check_date(v jsonb, path text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM store.check_match(v, path, '^[0-9]{4}-[0-9]{2}-[0-9]{2}$', 'a date such as 2026-11-01');
  PERFORM (v #>> '{}')::date;
EXCEPTION
  WHEN datetime_field_overflow OR invalid_datetime_format THEN
    PERFORM store.reject(path, 'is not a date that exists');
END
$$;

-- contract: central/test/schema.sql
CREATE FUNCTION store.check_latency_day(v jsonb, path text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  e record;
BEGIN
  PERFORM store.check_object(v, path, ARRAY[
    'endpoint', 'unit_id', 'date', 'poller_started_at', 'buckets_version', 'retries',
    'timeouts', 'max_ms', 'buckets']);
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
END
$$;

-- contract: central/test/schema.sql
CREATE OR REPLACE FUNCTION store.check_batch(b jsonb) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  e record;
BEGIN
  PERFORM store.check_object(b, 'batch', ARRAY[
    'schema_version', 'batch_id', 'sent_at', 'clock', 'backlog', 'readings', 'missed_reads'],
    ARRAY['firmware_reads', 'clock_checks', 'latency']);
  IF b -> 'schema_version' <> '1'::jsonb THEN
    PERFORM store.reject('batch.schema_version', 'must be 1');
  END IF;
  PERFORM store.check_match(b -> 'batch_id', 'batch.batch_id',
    '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$', 'a UUID');
  PERFORM store.check_datetime(b -> 'sent_at', 'batch.sent_at');

  PERFORM store.check_object(b -> 'clock', 'batch.clock', ARRAY['source', 'last_sync_at']);
  PERFORM store.check_enum(b -> 'clock' -> 'source', 'batch.clock.source',
    enum_range(NULL::store.clock_source)::text[]);
  PERFORM store.check_nullable_datetime(b -> 'clock' -> 'last_sync_at', 'batch.clock.last_sync_at');

  PERFORM store.check_object(b -> 'backlog', 'batch.backlog', ARRAY[
    'events', 'bytes', 'batches', 'oldest', 'max_bytes', 'refused', 'discarded_files',
    'quarantined']);
  PERFORM store.check_count(b -> 'backlog' -> f, 'batch.backlog.' || f, 0)
    FROM unnest(ARRAY['events', 'bytes', 'batches', 'refused', 'discarded_files', 'quarantined']) f;
  PERFORM store.check_count(b -> 'backlog' -> 'max_bytes', 'batch.backlog.max_bytes', 1);
  PERFORM store.check_nullable_datetime(b -> 'backlog' -> 'oldest', 'batch.backlog.oldest');

  PERFORM store.check_array(b -> 'readings', 'batch.readings', 0, 2147483647);
  FOR e IN SELECT value, ordinality - 1 AS i FROM jsonb_array_elements(b -> 'readings') WITH ORDINALITY LOOP
    PERFORM store.check_reading(e.value, format('batch.readings[%s]', e.i));
  END LOOP;

  PERFORM store.check_array(b -> 'missed_reads', 'batch.missed_reads', 0, 2147483647);
  FOR e IN SELECT value, ordinality - 1 AS i FROM jsonb_array_elements(b -> 'missed_reads') WITH ORDINALITY LOOP
    PERFORM store.check_missed_read(e.value, format('batch.missed_reads[%s]', e.i));
  END LOOP;

  IF b ? 'firmware_reads' THEN
    PERFORM store.check_array(b -> 'firmware_reads', 'batch.firmware_reads', 0, 2147483647);
    FOR e IN SELECT value, ordinality - 1 AS i FROM jsonb_array_elements(b -> 'firmware_reads') WITH ORDINALITY LOOP
      PERFORM store.check_firmware_read(e.value, format('batch.firmware_reads[%s]', e.i));
    END LOOP;
  END IF;

  IF b ? 'clock_checks' THEN
    PERFORM store.check_array(b -> 'clock_checks', 'batch.clock_checks', 0, 2147483647);
    FOR e IN SELECT value, ordinality - 1 AS i FROM jsonb_array_elements(b -> 'clock_checks') WITH ORDINALITY LOOP
      PERFORM store.check_clock_check(e.value, format('batch.clock_checks[%s]', e.i));
    END LOOP;
  END IF;

  IF b ? 'latency' THEN
    PERFORM store.check_array(b -> 'latency', 'batch.latency', 0, 2147483647);
    FOR e IN SELECT value, ordinality - 1 AS i FROM jsonb_array_elements(b -> 'latency') WITH ORDINALITY LOOP
      PERFORM store.check_latency_day(e.value, format('batch.latency[%s]', e.i));
    END LOOP;
  END IF;
END
$$;

-- A checked batch's latency entries as rows; none when it carries none.
CREATE FUNCTION store.batch_latency_days(b jsonb)
RETURNS TABLE (
  endpoint_host text, endpoint_port integer, unit_id smallint, day date,
  poller_started_at timestamptz, buckets_version bigint, retries bigint, timeouts bigint,
  max_ms bigint, buckets bigint[]
)
LANGUAGE sql STABLE AS $$
  SELECT l -> 'endpoint' ->> 'host', (l -> 'endpoint' ->> 'port')::numeric::integer,
         (l ->> 'unit_id')::numeric::smallint, (l ->> 'date')::date,
         (l ->> 'poller_started_at')::timestamptz, (l ->> 'buckets_version')::numeric::bigint,
         (l ->> 'retries')::numeric::bigint, (l ->> 'timeouts')::numeric::bigint,
         (l ->> 'max_ms')::numeric::bigint,
         ARRAY(SELECT (n #>> '{}')::numeric::bigint
               FROM jsonb_array_elements(l -> 'buckets') WITH ORDINALITY q(n, i) ORDER BY i)
  FROM jsonb_array_elements(coalesce(b -> 'latency', '[]')) l
$$;

-- A checked batch's latency entries against the bucket versions and
-- themselves. An entry under a version the store has not loaded is refused
-- with 503, so the collector keeps the batch until it is; with 422, one whose
-- buckets are not one per bound and one above the last, whose retries
-- outnumber its answers (the sum of its buckets), whose max_ms is given with
-- no answer, missing with some, or not in its last bucket that counts any,
-- or whose poller started after its date ended.
-- contract: central/test/ingest.sql
CREATE FUNCTION store.check_latency(b jsonb) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  e record;
  path text;
  bounds integer[];
  answered numeric;
  k integer;
BEGIN
  FOR e IN
    SELECT ordinality - 1 AS i, l.*
    FROM store.batch_latency_days(b) WITH ORDINALITY l
  LOOP
    path := format('batch.latency[%s]', e.i);
    SELECT v.bounds_ms INTO bounds FROM store.latency_bucket_versions v
      WHERE v.version = e.buckets_version;
    IF NOT FOUND THEN
      RAISE SQLSTATE 'PT503' USING
        MESSAGE = format('%s: latency buckets version %s is not loaded in the store',
                         path, e.buckets_version),
        HINT = 'Load it with central/bin/load-profiles; the batch is accepted once it is.';
    END IF;
    IF cardinality(e.buckets) <> cardinality(bounds) + 1 THEN
      PERFORM store.reject(path || '.buckets', format(
        'must have %s counts, one per bound of latency buckets version %s and one above the last',
        cardinality(bounds) + 1, e.buckets_version));
    END IF;
    SELECT sum(n), max(i) FILTER (WHERE n > 0) INTO answered, k
      FROM unnest(e.buckets) WITH ORDINALITY u(n, i);
    IF e.retries > answered THEN
      PERFORM store.reject(path || '.retries', 'must be at most the answers, the sum of buckets');
    END IF;
    IF answered = 0 AND e.max_ms IS NOT NULL THEN
      PERFORM store.reject(path || '.max_ms', 'must be null when nothing answered');
    END IF;
    IF answered > 0 AND e.max_ms IS NULL THEN
      PERFORM store.reject(path || '.max_ms', 'must be given when something answered');
    END IF;
    IF answered > 0 AND NOT ((k = 1 OR e.max_ms > bounds[k - 1])
                             AND (k > cardinality(bounds) OR e.max_ms <= bounds[k])) THEN
      PERFORM store.reject(path || '.max_ms', format(
        'must be in the last bucket that counts an answer: %s',
        concat_ws(' and ', 'above ' || bounds[k - 1] || ' ms', 'at most ' || bounds[k] || ' ms')));
    END IF;
    IF e.poller_started_at >= (e.day + 1)::timestamp AT TIME ZONE 'UTC' THEN
      PERFORM store.reject(path || '.poller_started_at', 'must be before its date ended (UTC)');
    END IF;
  END LOOP;
END
$$;

-- Store a batch: POST /rpc/ingest with the batch as the JSON body. Answers
-- 200, 422 (schema, or a register its profile version does not name, or
-- latency its bucket version does not fit), 503 (a profile or bucket version
-- not loaded), 409 (batch id of another collector) or 403 (not a collector).
-- A batch with no readings or missed reads is a heartbeat; its answer, like
-- every answer, lists the collector's pending jobs.
-- contract: central/test/ingest.sql, central/test/requests.sql, central/test/latency.sql
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
  unknown_requests uuid[];
BEGIN
  IF caller IS NULL THEN
    RAISE SQLSTATE 'PT403' USING MESSAGE = 'the caller is not a registered collector';
  END IF;
  PERFORM store.check_batch(b);
  PERFORM store.check_catalog(b);
  PERFORM store.check_latency(b);
  id := (b ->> 'batch_id')::uuid;
  readings_in := jsonb_array_length(b -> 'readings');
  missed_in := jsonb_array_length(b -> 'missed_reads');
  firmware_in := coalesce(jsonb_array_length(b -> 'firmware_reads'), 0);
  checks_in := coalesce(jsonb_array_length(b -> 'clock_checks'), 0);
  latency_in := coalesce(jsonb_array_length(b -> 'latency'), 0);

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
       timeouts, max_ms, buckets, collector_id, batch_id)
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
  WHERE (s.buckets_version, s.retries, s.timeouts, s.max_ms, s.buckets)
        IS DISTINCT FROM (l.buckets_version, l.retries, l.timeouts, l.max_ms, l.buckets);

  unknown_requests := jobs.link_batch(b, caller, id);

  INSERT INTO store.uploads
    (batch_id, collector_id, received_at, sent_at, backlog_events, backlog_bytes,
     backlog_batches, backlog_oldest, backlog_max_bytes, backlog_refused,
     backlog_discarded_files, backlog_quarantined, readings_inserted, readings_duplicate,
     readings_conflicting, missed_reads_inserted, missed_reads_duplicate)
  SELECT id, caller, now(), (b ->> 'sent_at')::timestamptz,
         (k ->> 'events')::numeric, (k ->> 'bytes')::numeric, (k ->> 'batches')::numeric,
         (k ->> 'oldest')::timestamptz, (k ->> 'max_bytes')::numeric,
         (k ->> 'refused')::numeric, (k ->> 'discarded_files')::numeric,
         (k ->> 'quarantined')::numeric,
         readings_new, readings_in - readings_new - readings_conflicting, readings_conflicting,
         missed_new, missed_in - missed_new
  FROM (SELECT b -> 'backlog' AS k) backlog;

  -- jobs and unknown_requests are left out when there are none.
  RETURN jsonb_build_object(
    'batch_id', id,
    'resent', resent,
    'first_received_at', first_received,
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
      'conflicting', latency_conflicting))
    || jsonb_strip_nulls(jsonb_build_object(
         'jobs', jobs.pending(caller),
         'unknown_requests', to_jsonb(unknown_requests)));
END
$$;

-- The views call none of our functions, so health views may read them.
--
-- Percentiles as alavi's Alavi.Poller.Latency reads them: nearest rank, the
-- smallest bucket holding at least p % of the answers, shown as its upper
-- bound, never above the exact max (the max itself above the last bound).
-- NULL when nothing answered. Buckets merge only within a bucket version.

-- Each is one scan of store.latency_days, each entry's row once per bucket:
-- the entry's own figures (retries, timeouts, max) are the same on every one
-- of its rows, so they are summed per bucket and read from any. One scan, so
-- a bound on a key column (the health view's day) reaches it.

-- Per meter (collector, endpoint, unit), UTC day and bucket version, every
-- poller's entries for that day merged: a restart's part of a day with the
-- part before it.
-- contract: central/test/latency.sql
CREATE VIEW store.latency_meter_days AS
  WITH merged AS (
    SELECT d.collector_id, d.endpoint_host, d.endpoint_port, d.unit_id, d.day,
           d.buckets_version, b.i, sum(b.n) AS n, count(*) AS entries, sum(d.retries) AS retries,
           sum(d.timeouts) AS timeouts, max(d.max_ms) AS max_ms
    FROM store.latency_days d
    CROSS JOIN LATERAL unnest(d.buckets) WITH ORDINALITY b(n, i)
    GROUP BY d.collector_id, d.endpoint_host, d.endpoint_port, d.unit_id, d.day,
             d.buckets_version, b.i
  ),
  ranked AS (
    SELECT m.*, v.bounds_ms[m.i] AS upper_ms,
           sum(m.n) OVER (PARTITION BY m.collector_id, m.endpoint_host, m.endpoint_port,
                                       m.unit_id, m.day, m.buckets_version ORDER BY m.i)
             AS through,
           sum(m.n) OVER (PARTITION BY m.collector_id, m.endpoint_host, m.endpoint_port,
                                       m.unit_id, m.day, m.buckets_version) AS answered
    FROM merged m
    JOIN store.latency_bucket_versions v ON v.version = m.buckets_version
  ),
  figures AS (
    SELECT collector_id, endpoint_host, endpoint_port, unit_id, day, buckets_version,
           max(entries) AS entries, max(answered) AS answered,
           max(retries) AS retries, max(timeouts) AS timeouts, max(max_ms) AS max_ms,
           min(upper_ms) FILTER (WHERE through >= div(answered * 50 + 99, 100)) AS p50,
           min(upper_ms) FILTER (WHERE through >= div(answered * 90 + 99, 100)) AS p90,
           min(upper_ms) FILTER (WHERE through >= div(answered * 99 + 99, 100)) AS p99
    FROM ranked
    GROUP BY collector_id, endpoint_host, endpoint_port, unit_id, day, buckets_version
  )
  SELECT collector_id, endpoint_host, endpoint_port, unit_id, day, buckets_version, entries,
         answered::bigint AS answered,
         retries::bigint AS retries, timeouts::bigint AS timeouts,
         CASE WHEN answered > 0 THEN least(p50, max_ms) END AS p50_ms,
         CASE WHEN answered > 0 THEN least(p90, max_ms) END AS p90_ms,
         CASE WHEN answered > 0 THEN least(p99, max_ms) END AS p99_ms,
         max_ms
  FROM figures;

-- The same per endpoint (collector, host, port): every meter's entries for
-- the day merged.
-- contract: central/test/latency.sql
CREATE VIEW store.latency_endpoint_days AS
  WITH merged AS (
    SELECT d.collector_id, d.endpoint_host, d.endpoint_port, d.day, d.buckets_version, b.i,
           sum(b.n) AS n, count(*) AS entries, count(DISTINCT d.unit_id) AS meters,
           sum(d.retries) AS retries,
           sum(d.timeouts) AS timeouts, max(d.max_ms) AS max_ms
    FROM store.latency_days d
    CROSS JOIN LATERAL unnest(d.buckets) WITH ORDINALITY b(n, i)
    GROUP BY d.collector_id, d.endpoint_host, d.endpoint_port, d.day, d.buckets_version, b.i
  ),
  ranked AS (
    SELECT m.*, v.bounds_ms[m.i] AS upper_ms,
           sum(m.n) OVER (PARTITION BY m.collector_id, m.endpoint_host, m.endpoint_port, m.day,
                                       m.buckets_version ORDER BY m.i) AS through,
           sum(m.n) OVER (PARTITION BY m.collector_id, m.endpoint_host, m.endpoint_port, m.day,
                                       m.buckets_version) AS answered
    FROM merged m
    JOIN store.latency_bucket_versions v ON v.version = m.buckets_version
  ),
  figures AS (
    SELECT collector_id, endpoint_host, endpoint_port, day, buckets_version,
           max(entries) AS entries, max(meters) AS meters, max(answered) AS answered,
           max(retries) AS retries, max(timeouts) AS timeouts, max(max_ms) AS max_ms,
           min(upper_ms) FILTER (WHERE through >= div(answered * 50 + 99, 100)) AS p50,
           min(upper_ms) FILTER (WHERE through >= div(answered * 90 + 99, 100)) AS p90,
           min(upper_ms) FILTER (WHERE through >= div(answered * 99 + 99, 100)) AS p99
    FROM ranked
    GROUP BY collector_id, endpoint_host, endpoint_port, day, buckets_version
  )
  SELECT collector_id, endpoint_host, endpoint_port, day, buckets_version, entries, meters,
         answered::bigint AS answered,
         retries::bigint AS retries, timeouts::bigint AS timeouts,
         CASE WHEN answered > 0 THEN least(p50, max_ms) END AS p50_ms,
         CASE WHEN answered > 0 THEN least(p90, max_ms) END AS p90_ms,
         CASE WHEN answered > 0 THEN least(p99, max_ms) END AS p99_ms,
         max_ms
  FROM figures;

-- Per registered endpoint, as registered now, its latency on each UTC day
-- that overlaps the lookback, at each address it had while in service on
-- that day, per bucket version (counts under different bounds do not merge).
-- The lookback's days are found by index on the day before any is merged:
-- the bound on d.day refers to nothing but the thresholds, so it reaches
-- into store.latency_endpoint_days.
-- contract: central/test/latency.sql
CREATE VIEW health.endpoint_latency AS
  WITH t AS (SELECT * FROM health.thresholds),
  periods AS (
    SELECT h.endpoint_id, h.collector_id, h.host, h.port,
           greatest(lower(h.period), now() - t.lookback) AS since, upper(h.period) AS until
    FROM registry.endpoint_history h
    CROSS JOIN t
    WHERE h.in_service AND h.period && tstzrange(now() - t.lookback, now())
      AND EXISTS (SELECT FROM registry.endpoint_history n
                  WHERE n.endpoint_id = h.endpoint_id AND n.period @> now())
  )
  SELECT DISTINCT p.endpoint_id, p.collector_id, p.host, p.port, d.day, d.buckets_version,
         d.meters, d.entries, d.answered, d.retries, d.timeouts, d.p50_ms, d.p90_ms, d.p99_ms,
         d.max_ms
  FROM periods p
  JOIN store.latency_endpoint_days d
    ON (d.collector_id, d.endpoint_host, d.endpoint_port) = (p.collector_id, p.host, p.port)
   AND d.day >= (p.since AT TIME ZONE 'UTC')::date
   AND (p.until IS NULL OR d.day::timestamp AT TIME ZONE 'UTC' < p.until)
  WHERE d.day >= ((now() - (SELECT lookback FROM health.thresholds)) AT TIME ZONE 'UTC')::date;

GRANT SELECT ON health.endpoint_latency TO monitor;

-- migrate:down
-- Forward only: a rollback would drop raw data. Undo with a new migration.
