-- migrate:up

-- The collector's clock measured against an NTP server (SNTP), as batch.v1's
-- clock_checks carry it: the four times raw, the server's header fields when
-- it answered, and the outcome when it did not. Offset, delay and error bound
-- are views. Keyed on (collector, t1): a resent check is a duplicate.
CREATE TYPE store.clock_check_trigger AS ENUM ('start', 'daily', 'step');
CREATE TYPE store.clock_check_outcome AS ENUM (
  'answered', 'timeout', 'unreachable', 'kiss_of_death', 'invalid'
);

-- contract: central/test/ingest.sql
CREATE TABLE store.clock_checks (
  collector_id text NOT NULL REFERENCES store.collectors (id),
  t1 timestamptz NOT NULL,
  t4 timestamptz NOT NULL,
  trigger store.clock_check_trigger NOT NULL,
  server text NOT NULL CHECK (length(server) BETWEEN 1 AND 253),
  outcome store.clock_check_outcome NOT NULL,
  t2_unix numeric CHECK (scale(t2_unix) <= 9),
  t3_unix numeric CHECK (scale(t3_unix) <= 9),
  address inet,
  stratum smallint CHECK (stratum BETWEEN 1 AND 15),
  leap smallint CHECK (leap BETWEEN 0 AND 2),
  reference_id bigint CHECK (reference_id BETWEEN 0 AND 4294967295),
  batch_id uuid NOT NULL REFERENCES store.batches (batch_id),
  PRIMARY KEY (collector_id, t1),
  CONSTRAINT clock_checks_outcome_fields CHECK (CASE outcome
    WHEN 'answered' THEN num_nulls(t2_unix, t3_unix, address, stratum, leap, reference_id) = 0
    WHEN 'kiss_of_death' THEN num_nulls(address, reference_id) = 0
                              AND num_nonnulls(t2_unix, t3_unix, stratum, leap) = 0
    ELSE num_nonnulls(t2_unix, t3_unix, address, stratum, leap, reference_id) = 0
  END)
);
COMMENT ON COLUMN store.clock_checks.t1 IS
  'The collector''s clock when it sent the query, or tried to.';
COMMENT ON COLUMN store.clock_checks.t4 IS
  'The collector''s clock when the reply came, or it gave up waiting.';
-- timestamptz holds microseconds; the server's times come at nanoseconds.
COMMENT ON COLUMN store.clock_checks.t2_unix IS
  'The server''s clock when it received the query: seconds since 1970-01-01T00:00:00Z (Unix time, no leap seconds), exact to the digits sent (at most nanoseconds). store.clock_offsets shows it as a timestamptz too.';
COMMENT ON COLUMN store.clock_checks.t3_unix IS
  'The server''s clock when it sent its reply, as t2_unix.';
COMMENT ON COLUMN store.clock_checks.reference_id IS
  'The reply''s reference identifier, its 32 bits unsigned; store.clock_check_references decodes it.';
-- For grounding readings and the health view's last answered check.
CREATE INDEX ON store.clock_checks (collector_id, t1) WHERE outcome = 'answered';

CREATE TRIGGER refuse_change BEFORE UPDATE OR DELETE ON store.clock_checks
  FOR EACH ROW EXECUTE FUNCTION store.refuse_change();
CREATE TRIGGER refuse_truncate BEFORE TRUNCATE ON store.clock_checks
  FOR EACH STATEMENT EXECUTE FUNCTION store.refuse_change();

-- A date-time to at most `digits` fraction digits.
CREATE FUNCTION store.check_time(v jsonb, path text, digits integer, finest text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM store.check_datetime(v, path);
  PERFORM store.check_match(v, path,
    format('^[^.]*(\.[0-9]{1,%s})?([Zz]|[+-][0-9]{2}:[0-9]{2})$', digits),
    'a date-time to at most ' || finest);
END
$$;

-- JSON Schema's "ipv4" (dotted decimal, no leading zeros) or "ipv6" (no
-- prefix length, no zone).
CREATE FUNCTION store.check_ip(v jsonb, path text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  octet text := '(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])';
  s text := v #>> '{}';
BEGIN
  IF jsonb_typeof(v) = 'string'
     AND (s ~ format('^%s(\.%s){3}$', octet, octet)
          OR (s ~ '^[0-9A-Fa-f:.]*:[0-9A-Fa-f:.]*$' AND family(s::inet) = 6)) THEN
    RETURN;
  END IF;
  PERFORM store.reject(path, 'must be an IPv4 or IPv6 address');
EXCEPTION
  WHEN invalid_text_representation THEN
    PERFORM store.reject(path, 'must be an IPv4 or IPv6 address');
END
$$;

-- The fields an outcome carries: answered, the server's times and header
-- fields; kiss_of_death, the address and kiss code; any other, none.
-- contract: central/test/schema.sql
CREATE FUNCTION store.check_clock_check(v jsonb, path text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  always text[] := ARRAY['trigger', 'server', 'outcome', 't1', 't4'];
  answer text[] := ARRAY['t2', 't3', 'address', 'stratum', 'leap', 'reference_id'];
BEGIN
  PERFORM store.check_object(v, path, always, answer);
  PERFORM store.check_enum(v -> 'outcome', path || '.outcome',
    enum_range(NULL::store.clock_check_outcome)::text[]);
  PERFORM store.check_object(v, path, always || CASE v ->> 'outcome'
    WHEN 'answered' THEN answer
    WHEN 'kiss_of_death' THEN ARRAY['address', 'reference_id']
    ELSE '{}'::text[]
  END);
  PERFORM store.check_enum(v -> 'trigger', path || '.trigger',
    enum_range(NULL::store.clock_check_trigger)::text[]);
  PERFORM store.check_string(v -> 'server', path || '.server', 253);
  PERFORM store.check_time(v -> t, path || '.' || t, 6, 'microseconds')
    FROM unnest(ARRAY['t1', 't4']) t;
  IF v ? 't2' THEN
    PERFORM store.check_time(v -> t, path || '.' || t, 9, 'nanoseconds')
      FROM unnest(ARRAY['t2', 't3']) t;
    PERFORM store.check_integer(v -> 'stratum', path || '.stratum', 1, 15);
    PERFORM store.check_integer(v -> 'leap', path || '.leap', 0, 2);
  END IF;
  IF v ? 'address' THEN
    PERFORM store.check_ip(v -> 'address', path || '.address');
    PERFORM store.check_integer(v -> 'reference_id', path || '.reference_id', 0, 4294967295);
  END IF;
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
    ARRAY['firmware_reads', 'clock_checks']);
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
END
$$;

-- A checked date-time as Unix time, every fraction digit kept: the whole
-- seconds through timestamptz, the fraction as written.
CREATE FUNCTION store.unix_time(t text) RETURNS numeric
LANGUAGE sql STABLE STRICT AS $$
  SELECT extract(epoch FROM regexp_replace(t, '\.[0-9]+', '')::timestamptz)::bigint
         + coalesce(('0' || substring(t FROM '\.[0-9]+'))::numeric, 0)
$$;

-- A checked batch's clock checks as rows; none when it carries none.
CREATE FUNCTION store.batch_clock_checks(b jsonb)
RETURNS TABLE (
  t1 timestamptz, t4 timestamptz, trigger store.clock_check_trigger, server text,
  outcome store.clock_check_outcome, t2_unix numeric, t3_unix numeric, address inet,
  stratum smallint, leap smallint, reference_id bigint
)
LANGUAGE sql STABLE AS $$
  SELECT (c ->> 't1')::timestamptz, (c ->> 't4')::timestamptz,
         (c ->> 'trigger')::store.clock_check_trigger, c ->> 'server',
         (c ->> 'outcome')::store.clock_check_outcome,
         store.unix_time(c ->> 't2'), store.unix_time(c ->> 't3'), (c ->> 'address')::inet,
         (c ->> 'stratum')::numeric::smallint, (c ->> 'leap')::numeric::smallint,
         (c ->> 'reference_id')::numeric::bigint
  FROM jsonb_array_elements(coalesce(b -> 'clock_checks', '[]')) c
$$;

-- Store a batch: POST /rpc/ingest with the batch as the JSON body. Answers
-- 200, 422 (schema, or a register its profile version does not name), 503
-- (a profile version not loaded), 409 (batch id of another collector) or 403
-- (not a collector). A batch with no readings or missed reads is a
-- heartbeat; its answer, like every answer, lists the collector's pending jobs.
-- contract: central/test/ingest.sql, central/test/requests.sql
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
  unknown_requests uuid[];
BEGIN
  IF caller IS NULL THEN
    RAISE SQLSTATE 'PT403' USING MESSAGE = 'the caller is not a registered collector';
  END IF;
  PERFORM store.check_batch(b);
  PERFORM store.check_catalog(b);
  id := (b ->> 'batch_id')::uuid;
  readings_in := jsonb_array_length(b -> 'readings');
  missed_in := jsonb_array_length(b -> 'missed_reads');
  firmware_in := coalesce(jsonb_array_length(b -> 'firmware_reads'), 0);
  checks_in := coalesce(jsonb_array_length(b -> 'clock_checks'), 0);

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
      'conflicting', checks_conflicting))
    || jsonb_strip_nulls(jsonb_build_object(
         'jobs', jobs.pending(caller),
         'unknown_requests', to_jsonb(unknown_requests)));
END
$$;

-- The views call none of our functions, so health views may read them.

-- Each reference identifier decoded (RFC 5905): a kiss code (kiss_of_death)
-- or a stratum 1 server's source as up to four ASCII characters, NULs
-- dropped and anything else unprintable as ?; any other stratum's as a dotted
-- quad (a server's IPv4 address; for an IPv6 server, a hash of its address).
-- contract: central/test/clock.sql
CREATE VIEW store.clock_check_references AS
  SELECT c.collector_id, c.t1, c.outcome, c.stratum, c.reference_id,
         CASE WHEN c.outcome = 'kiss_of_death' OR c.stratum = 1 THEN
           (SELECT string_agg(CASE WHEN o BETWEEN 32 AND 126 THEN chr(o)
                                   WHEN o = 0 THEN ''
                                   ELSE '?' END, '' ORDER BY i)
            FROM (SELECT i, ((c.reference_id >> (24 - 8 * i)) & 255)::integer AS o
                  FROM generate_series(0, 3) i) octets)
         ELSE format('%s.%s.%s.%s', c.reference_id >> 24, (c.reference_id >> 16) & 255,
                     (c.reference_id >> 8) & 255, c.reference_id & 255)
         END AS reference
  FROM store.clock_checks c
  WHERE c.reference_id IS NOT NULL;

-- Per answered check, the NTP figures in seconds, exact: offset
-- ((t2 − t1) + (t3 − t4)) / 2, what to add to the collector's clock to get
-- the server's; delay (t4 − t1) − (t3 − t2), the round trip less the server's
-- time; and error bound delay / 2, within which the true offset lies. t2 and
-- t3 are shown as timestamptz too, cut to microseconds.
-- contract: central/test/clock.sql
CREATE VIEW store.clock_offsets AS
  SELECT c.collector_id, c.t1,
         timestamptz 'epoch' + (floor(c.t2_unix * 1000000) * 0.000001 || ' seconds')::interval AS t2,
         timestamptz 'epoch' + (floor(c.t3_unix * 1000000) * 0.000001 || ' seconds')::interval AS t3,
         c.t4, c.t2_unix, c.t3_unix,
         trim_scale(((c.t2_unix - t.t1_unix) + (c.t3_unix - t.t4_unix)) * 0.5) AS offset_seconds,
         trim_scale((t.t4_unix - t.t1_unix) - (c.t3_unix - c.t2_unix)) AS delay_seconds,
         trim_scale(((t.t4_unix - t.t1_unix) - (c.t3_unix - c.t2_unix)) * 0.5)
           AS error_bound_seconds,
         c.server, c.address, c.stratum, c.leap, c.reference_id, r.reference, c.trigger,
         c.batch_id
  FROM store.clock_checks c
  CROSS JOIN LATERAL (SELECT extract(epoch FROM c.t1) AS t1_unix,
                             extract(epoch FROM c.t4) AS t4_unix) t
  JOIN store.clock_check_references r USING (collector_id, t1)
  WHERE c.outcome = 'answered';

-- Per upload, the fallback reference: the store's clock on arrival against
-- the collector's when it sent. One-sided: the batch was in transit for an
-- unknown time, so the collector's offset (as in store.clock_offsets) is at
-- most received_at − sent_at, never known to be that.
-- contract: central/test/clock.sql
CREATE VIEW store.upload_clock_offsets AS
  SELECT u.collector_id, u.upload_id, u.batch_id, u.sent_at, u.received_at,
         trim_scale(extract(epoch FROM u.received_at) - extract(epoch FROM u.sent_at))
           AS offset_at_most_seconds
  FROM store.uploads u;
COMMENT ON COLUMN store.upload_clock_offsets.offset_at_most_seconds IS
  'An upper bound only: the true offset is this less the unknown transit time.';

-- Readings with no answered check by their collector within 48 hours of
-- them, before or after, by the collector's clock (read_at and t1 both are):
-- nothing places them in true time. With the nearest answered checks either
-- side, if any.
-- contract: central/test/clock.sql
CREATE VIEW store.ungrounded_readings AS
  SELECT r.meter_serial, r.register_key, r.read_at, r.collector_id, r.batch_id,
         (SELECT max(c.t1) FROM store.clock_checks c
          WHERE c.collector_id = r.collector_id AND c.outcome = 'answered' AND c.t1 <= r.read_at)
           AS previous_check_at,
         (SELECT min(c.t1) FROM store.clock_checks c
          WHERE c.collector_id = r.collector_id AND c.outcome = 'answered' AND c.t1 > r.read_at)
           AS next_check_at
  FROM store.readings r
  WHERE NOT EXISTS (
    SELECT FROM store.clock_checks c
    WHERE c.collector_id = r.collector_id AND c.outcome = 'answered'
      AND c.t1 BETWEEN r.read_at - interval '48 hours' AND r.read_at + interval '48 hours');

-- Per collector, its last clock check (by its own clock), and its last
-- answered one: when the server sent it, by the server's clock, and the
-- offset and error bound it gave; and the offset bound of its latest upload.
-- Unchecked: in service, not silent, and no answered check in the last 48
-- hours by the server's clock (counted from registration when it has none).
-- The server is shown with control characters as ?.
-- contract: central/test/clock.sql
CREATE VIEW health.collector_clocks AS
  SELECT c.collector_id, c.in_service,
         l.t1 AS last_check_at, l.outcome AS last_outcome,
         regexp_replace(l.server, '[[:cntrl:]]', '?', 'g') AS last_server, lr.reference AS last_reference,
         a.t3 AS last_answered_at, a.offset_seconds, a.error_bound_seconds,
         u.offset_at_most_seconds AS upload_offset_at_most_seconds,
         c.in_service AND NOT c.silent
           AND coalesce(a.t3, s.created_at) < now() - interval '48 hours' AS unchecked
  FROM health.collectors c
  JOIN store.collectors s ON s.id = c.collector_id
  LEFT JOIN LATERAL (
    SELECT * FROM store.clock_checks x WHERE x.collector_id = c.collector_id
    ORDER BY x.t1 DESC LIMIT 1
  ) l ON true
  LEFT JOIN store.clock_check_references lr ON (lr.collector_id, lr.t1) = (l.collector_id, l.t1)
  LEFT JOIN LATERAL (
    SELECT * FROM store.clock_offsets x WHERE x.collector_id = c.collector_id
    ORDER BY x.t1 DESC LIMIT 1
  ) a ON true
  LEFT JOIN LATERAL (
    SELECT * FROM store.upload_clock_offsets x WHERE x.collector_id = c.collector_id
    ORDER BY x.received_at DESC, x.upload_id DESC LIMIT 1
  ) u ON true;

-- One row per problem: (kind, subject) names it, detail describes it now.
-- contract: central/test/health.sql, central/test/clock.sql
CREATE OR REPLACE VIEW health.problems AS
  SELECT 'collector_silent' AS kind, c.collector_id AS subject,
         format('no upload since %s (%s endpoints in service)',
                coalesce(c.last_upload_at::text, 'it was registered'), c.endpoints) AS detail
  FROM health.collectors c WHERE c.silent
  UNION ALL
  SELECT 'backlog_near_capacity', c.collector_id,
         format('backlog %s of %s bytes (%s%%), oldest %s', c.backlog_bytes, c.backlog_max_bytes,
                round(c.backlog_used * 100, 1), c.backlog_oldest)
  FROM health.collectors c WHERE c.backlog_near_capacity
  UNION ALL
  SELECT 'backlog_refused', c.collector_id,
         format('%s events refused since the collector started', c.backlog_refused)
  FROM health.collectors c WHERE c.has_refused
  UNION ALL
  SELECT 'backlog_discarded', c.collector_id,
         format('%s .discarded files in the buffer', c.backlog_discarded_files)
  FROM health.collectors c WHERE c.has_discarded
  UNION ALL
  SELECT 'backlog_quarantined', c.collector_id,
         format('%s batches in quarantine', c.backlog_quarantined)
  FROM health.collectors c WHERE c.has_quarantined
  UNION ALL
  SELECT 'clock_unchecked', k.collector_id,
         CASE WHEN k.last_check_at IS NULL THEN 'no clock check since it was registered'
         ELSE format('no answered clock check since %s; the last check, at %s by its clock, '
                     || 'was %s from %s',
                     coalesce(k.last_answered_at::text, 'it was registered'), k.last_check_at,
                     k.last_outcome || CASE WHEN k.last_outcome = 'kiss_of_death'
                                            THEN ' ' || k.last_reference ELSE '' END,
                     k.last_server)
         END
  FROM health.collector_clocks k WHERE k.unchecked
  UNION ALL
  SELECT 'meter_silent', m.serial,
         format('no reading since %s (expected every %s), on %s unit %s, collector %s',
                coalesce(m.last_reading_at::text, 'it came into service'), m.expected_interval,
                m.endpoint_id, m.unit_id, m.collector_id)
  FROM health.meters m
  JOIN health.collectors c USING (collector_id)
  WHERE m.silent AND NOT c.silent
  UNION ALL
  SELECT 'unregistered_serial', u.serial,
         format('%s readings, the last at %s, from %s', u.readings, u.last_reading_at,
                array_to_string(u.collectors, ', '))
  FROM health.unregistered_serials u
  UNION ALL
  SELECT 'misplaced_serial', p.serial,
         string_agg(format('%s readings, the last at %s, at %s:%s unit %s via %s (registered at %s)',
                           p.readings, p.last_reading_at, p.endpoint_host, p.endpoint_port,
                           p.unit_id, p.collector_id, array_to_string(p.registered_at, ', ')),
                    '; ' ORDER BY p.collector_id, p.endpoint_host, p.endpoint_port, p.unit_id)
  FROM health.misplaced_serials p
  GROUP BY p.serial
  UNION ALL
  SELECT 'serial_at_several_places', u.serial,
         string_agg(format('%s readings, the last at %s, at %s:%s unit %s via %s',
                           u.readings, u.last_reading_at, u.endpoint_host, u.endpoint_port,
                           u.unit_id, u.collector_id),
                    '; ' ORDER BY u.collector_id, u.endpoint_host, u.endpoint_port, u.unit_id)
  FROM health.unregistered_serial_places u
  GROUP BY u.serial
  HAVING count(*) > 1
  UNION ALL
  SELECT 'several_serials_at_place',
         format('%s:%s unit %s via %s', s.endpoint_host, s.endpoint_port, s.unit_id, s.collector_id),
         string_agg(format('%s: %s readings, from %s to %s', s.serial, s.readings,
                           s.first_reading_at, s.last_reading_at),
                    '; ' ORDER BY s.first_reading_at, s.serial)
  FROM health.place_serials s
  GROUP BY s.collector_id, s.endpoint_host, s.endpoint_port, s.unit_id
  UNION ALL
  SELECT 'firmware_changed', f.serial,
         format('software %s, firmware %s / %s, modbus %s (read %s) became '
                || 'software %s, firmware %s / %s, modbus %s (read %s), at %s:%s unit %s via %s',
                coalesce(f.previous_software, '(none)'), coalesce(f.previous_firmware_1, '(none)'),
                coalesce(f.previous_firmware_2, '(none)'),
                coalesce(f.previous_modbus_version, '(none)'), f.previous_read_at,
                coalesce(f.software, '(none)'), coalesce(f.firmware_1, '(none)'),
                coalesce(f.firmware_2, '(none)'), coalesce(f.modbus_version, '(none)'), f.first_read_at,
                f.endpoint_host, f.endpoint_port, f.unit_id, f.collector_id)
  FROM health.meter_firmware f
  CROSS JOIN health.thresholds t
  WHERE f.changed AND f.first_received_at > now() - t.lookback;

GRANT SELECT ON health.collector_clocks TO monitor;

-- migrate:down
-- Forward only: a rollback would drop raw data. Undo with a new migration.
