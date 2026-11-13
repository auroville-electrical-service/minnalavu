-- migrate:up

-- Readings carry the product code the meter reported, beside the serial it
-- reported. A missed read is a fact about an address: it carries the serial
-- read in its round, or NULL when none was, and is keyed on where it was due.

ALTER TABLE store.readings ADD COLUMN product_code text;
ALTER TABLE store.reading_conflicts ADD COLUMN product_code text;
COMMENT ON COLUMN store.readings.meter_serial IS
  'The serial the meter reported in the round the reading was taken in.';
COMMENT ON COLUMN store.readings.product_code IS
  'The product code the meter reported in that round; NULL where the batch carried none.';

-- A host and port are unique only per collector (registry.check_history), so
-- the collector is part of the address.
-- contract: central/test/ingest.sql
ALTER TABLE store.missed_reads ALTER COLUMN meter_serial DROP NOT NULL;
ALTER TABLE store.missed_reads DROP CONSTRAINT missed_reads_key;
ALTER TABLE store.missed_reads ADD CONSTRAINT missed_reads_key
  UNIQUE (collector_id, endpoint_host, endpoint_port, unit_id, register_key, read_at);
COMMENT ON COLUMN store.missed_reads.meter_serial IS
  'The serial the meter reported in that round, or NULL when it could not be read.';
-- The dropped key's index served the health views' lookups by serial.
CREATE INDEX ON store.missed_reads (meter_serial, read_at DESC);

-- Exactly these fields: those in fields required, those in optional allowed.
CREATE FUNCTION store.check_object(v jsonb, path text, fields text[], optional text[])
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  missing text;
  unknown text;
BEGIN
  IF jsonb_typeof(v) IS DISTINCT FROM 'object' THEN
    PERFORM store.reject(path, 'must be an object');
  END IF;
  SELECT string_agg(f, ', ' ORDER BY f) INTO missing FROM unnest(fields) f WHERE NOT v ? f;
  IF missing IS NOT NULL THEN
    PERFORM store.reject(path, 'is missing ' || missing);
  END IF;
  SELECT string_agg(k, ', ' ORDER BY k) INTO unknown
    FROM jsonb_object_keys(v) k WHERE k <> ALL (fields || optional);
  IF unknown IS NOT NULL THEN
    PERFORM store.reject(path, 'has unknown field(s) ' || unknown);
  END IF;
END
$$;

CREATE OR REPLACE FUNCTION store.check_object(v jsonb, path text, fields text[]) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM store.check_object(v, path, fields, '{}'::text[]);
END
$$;

-- The fields a reading and a missed read share; the serial is checked by each.
CREATE OR REPLACE FUNCTION store.check_event(v jsonb, path text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM store.check_object(v -> 'endpoint', path || '.endpoint', ARRAY['host', 'port']);
  PERFORM store.check_string(v -> 'endpoint' -> 'host', path || '.endpoint.host', 2147483647);
  PERFORM store.check_integer(v -> 'endpoint' -> 'port', path || '.endpoint.port', 1, 65535);
  PERFORM store.check_integer(v -> 'unit_id', path || '.unit_id', 1, 247);
  PERFORM store.check_string(v -> 'profile', path || '.profile', 2147483647);
  PERFORM store.check_string(v -> 'register_key', path || '.register_key', 2147483647);
  PERFORM store.check_datetime(v -> 'timestamp', path || '.timestamp');
END
$$;

CREATE OR REPLACE FUNCTION store.check_reading(v jsonb, path text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM store.check_object(v, path, ARRAY[
    'endpoint', 'unit_id', 'meter_serial', 'profile', 'register_key', 'timestamp',
    'raw_words', 'value', 'unit'], ARRAY['product_code']);
  PERFORM store.check_event(v, path);
  PERFORM store.check_string(v -> 'meter_serial', path || '.meter_serial', 2147483647);
  IF v ? 'product_code' THEN
    PERFORM store.check_string(v -> 'product_code', path || '.product_code', 2147483647);
  END IF;
  PERFORM store.check_words(v -> 'raw_words', path || '.raw_words', 1, 4);
  PERFORM store.check_match(v -> 'value', path || '.value', '^-?[0-9]+(\.[0-9]+)?$',
    'a decimal string such as "1234.56"');
  PERFORM store.check_enum(v -> 'unit', path || '.unit',
    enum_range(NULL::store.reading_unit)::text[]);
END
$$;

CREATE OR REPLACE FUNCTION store.check_missed_read(v jsonb, path text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM store.check_object(v, path, ARRAY[
    'endpoint', 'unit_id', 'meter_serial', 'profile', 'register_key', 'timestamp',
    'reason', 'exception_code', 'detail', 'attempts', 'raw_words']);
  PERFORM store.check_event(v, path);
  IF v -> 'meter_serial' <> 'null'::jsonb THEN
    PERFORM store.check_string(v -> 'meter_serial', path || '.meter_serial', 2147483647);
  END IF;
  PERFORM store.check_enum(v -> 'reason', path || '.reason',
    enum_range(NULL::store.missed_reason)::text[]);
  IF v -> 'exception_code' <> 'null'::jsonb THEN
    PERFORM store.check_integer(v -> 'exception_code', path || '.exception_code', 1, 255);
  END IF;
  IF v -> 'detail' <> 'null'::jsonb THEN
    PERFORM store.check_string(v -> 'detail', path || '.detail', 200);
  END IF;
  PERFORM store.check_count(v -> 'attempts', path || '.attempts', 0);
  IF v -> 'raw_words' <> 'null'::jsonb THEN
    PERFORM store.check_words(v -> 'raw_words', path || '.raw_words', 0, 125);
  END IF;
END
$$;

-- Its result gains a column, which CREATE OR REPLACE cannot do.
DROP FUNCTION store.batch_readings(jsonb);
CREATE FUNCTION store.batch_readings(b jsonb)
RETURNS TABLE (
  meter_serial text, register_key text, read_at timestamptz, value numeric,
  unit store.reading_unit, raw_words integer[], profile text, endpoint_host text,
  endpoint_port integer, unit_id smallint, product_code text
)
LANGUAGE sql STABLE AS $$
  SELECT r ->> 'meter_serial', r ->> 'register_key', (r ->> 'timestamp')::timestamptz,
         (r ->> 'value')::numeric, (r ->> 'unit')::store.reading_unit,
         ARRAY(SELECT w::numeric::integer FROM jsonb_array_elements_text(r -> 'raw_words') w),
         r ->> 'profile', r -> 'endpoint' ->> 'host',
         (r -> 'endpoint' ->> 'port')::numeric::integer, (r ->> 'unit_id')::numeric::smallint,
         r ->> 'product_code'
  FROM jsonb_array_elements(b -> 'readings') r
$$;

-- Store a batch: POST /rpc/ingest with the batch as the JSON body. Answers
-- 200, 422 (schema), 409 (batch id of another collector) or 403 (not a collector).
-- contract: central/test/ingest.sql
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
BEGIN
  IF caller IS NULL THEN
    RAISE SQLSTATE 'PT403' USING MESSAGE = 'the caller is not a registered collector';
  END IF;
  PERFORM store.check_batch(b);
  id := (b ->> 'batch_id')::uuid;
  readings_in := jsonb_array_length(b -> 'readings');
  missed_in := jsonb_array_length(b -> 'missed_reads');

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
      (meter_serial, register_key, read_at, value, unit, raw_words, profile, endpoint_host,
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
    WHERE (s.value::text, s.unit, s.raw_words, s.profile, s.endpoint_host, s.endpoint_port,
           s.unit_id, s.product_code)
          IS DISTINCT FROM
          (r.value::text, r.unit, r.raw_words, r.profile, r.endpoint_host, r.endpoint_port,
           r.unit_id, r.product_code)
  ), kept AS (
    INSERT INTO store.reading_conflicts
      (meter_serial, register_key, read_at, value, unit, raw_words, profile, endpoint_host,
       endpoint_port, unit_id, product_code, collector_id, batch_id, received_at)
    SELECT d.*, caller, id, now() FROM differing d
    ON CONFLICT DO NOTHING
  )
  SELECT count(*) INTO readings_conflicting FROM differing;

  WITH inserted AS (
    INSERT INTO store.missed_reads
      (meter_serial, register_key, read_at, reason, exception_code, detail, attempts, raw_words,
       profile, endpoint_host, endpoint_port, unit_id, collector_id, batch_id)
    SELECT m.*, caller, id FROM store.batch_missed_reads(b) m
    ON CONFLICT (collector_id, endpoint_host, endpoint_port, unit_id, register_key, read_at)
      DO NOTHING
    RETURNING 1
  )
  SELECT count(*) INTO missed_new FROM inserted;

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
      'duplicate', missed_in - missed_new));
END
$$;

-- A missed read counts for the meter that reported the serial on it or, when
-- no serial was read, for the meter registered at its address now.
-- contract: central/test/health.sql
CREATE OR REPLACE VIEW health.meters AS
  WITH t AS (SELECT * FROM health.thresholds),
  m AS (
    SELECT m.serial, m.in_service, m.endpoint_id, m.unit_id, m.profile, e.collector_id,
           e.host, e.port, e.polled_by_other_system,
           m.in_service AND e.in_service AND NOT e.polled_by_other_system AS expected,
           coalesce(m.interval_ms, e.interval_ms) * interval '1 millisecond' AS expected_interval,
           coalesce(
             (SELECT max(upper(x.period)) FROM registry.meter_history x
              WHERE x.serial = m.serial AND NOT x.in_service AND upper(x.period) <= now()),
             (SELECT min(x.valid_from) FROM registry.meter_versions x WHERE x.serial = m.serial))
             AS in_service_since,
           (SELECT max(r.read_at) FROM store.readings r WHERE r.meter_serial = m.serial)
             AS last_reading_at
    FROM registry.meter_history m
    JOIN registry.endpoint_history e ON e.endpoint_id = m.endpoint_id AND e.period @> now()
    WHERE m.period @> now()
  )
  SELECT m.serial, m.in_service, m.collector_id, m.endpoint_id, m.unit_id, m.profile,
         m.polled_by_other_system, m.expected, m.expected_interval, m.in_service_since,
         m.last_reading_at,
         coalesce(x.missed, 0) AS missed_reads, coalesce(x.by_reason, '{}') AS missed_by_reason,
         m.expected
           AND greatest(m.last_reading_at, m.in_service_since)
               < now() - t.meter_silent_intervals * m.expected_interval AS silent
  FROM m
  CROSS JOIN t
  LEFT JOIN LATERAL (
    SELECT sum(n) AS missed, jsonb_object_agg(reason::text, n) AS by_reason
    FROM (SELECT r.reason, count(*) AS n FROM store.missed_reads r
          WHERE r.read_at > now() - t.lookback
            AND (r.meter_serial = m.serial
                 OR (r.meter_serial IS NULL AND r.collector_id = m.collector_id
                     AND r.endpoint_host = m.host AND r.endpoint_port = m.port
                     AND r.unit_id = m.unit_id))
          GROUP BY r.reason) g
  ) x ON true;

-- Registered serials read within the lookback somewhere other than where the
-- registry placed them when the reading was taken: one row per serial and
-- place read. A reading from before the serial's first registry row is not
-- judged. The host is shown cut to 100 characters, control characters as ?.
-- contract: central/test/health.sql
CREATE VIEW health.misplaced_serials AS
  SELECT r.meter_serial AS serial, r.collector_id,
         regexp_replace(left(r.endpoint_host, 100), '[[:cntrl:]]', '?', 'g') AS endpoint_host,
         r.endpoint_port, r.unit_id,
         count(*) AS readings, max(r.read_at) AS last_reading_at,
         array_agg(DISTINCT format('%s unit %s', m.endpoint_id, m.unit_id)) AS registered_at
  FROM store.readings r
  CROSS JOIN health.thresholds t
  JOIN registry.meter_history m ON m.serial = r.meter_serial AND m.period @> r.read_at
  JOIN registry.endpoint_history e ON e.endpoint_id = m.endpoint_id AND e.period @> r.read_at
  WHERE r.read_at > now() - t.lookback
    AND (r.collector_id, r.endpoint_host, r.endpoint_port, r.unit_id)
        IS DISTINCT FROM (e.collector_id, e.host, e.port, m.unit_id)
  GROUP BY r.meter_serial, r.collector_id, r.endpoint_host, r.endpoint_port, r.unit_id;

-- One row per problem: (kind, subject) names it, detail describes it now.
-- contract: central/test/health.sql
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
  GROUP BY p.serial;

GRANT SELECT ON health.misplaced_serials TO monitor;

-- migrate:down
-- Forward only: a rollback would drop raw data. Undo with a new migration.
