-- migrate:up

-- Checks of a batch against contract/schema/batch.v1.schema.json. Each raises
-- SQLSTATE PT422, which PostgREST answers with HTTP 422.
-- contract: central/test/schema.sql

CREATE FUNCTION store.reject(path text, problem text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  RAISE SQLSTATE 'PT422' USING
    MESSAGE = format('batch rejected: %s %s', path, problem),
    HINT = 'A batch must match contract/schema/batch.v1.schema.json.';
END
$$;

-- Exactly these fields: all required, no others.
CREATE FUNCTION store.check_object(v jsonb, path text, fields text[]) RETURNS void
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
    FROM jsonb_object_keys(v) k WHERE k <> ALL (fields);
  IF unknown IS NOT NULL THEN
    PERFORM store.reject(path, 'has unknown field(s) ' || unknown);
  END IF;
END
$$;

CREATE FUNCTION store.check_array(v jsonb, path text, min_items integer, max_items integer)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF jsonb_typeof(v) IS DISTINCT FROM 'array'
     OR jsonb_array_length(v) < min_items
     OR jsonb_array_length(v) > max_items THEN
    PERFORM store.reject(path, format('must be a list of %s to %s items', min_items, max_items));
  END IF;
END
$$;

-- A JSON integer: 502.0 counts.
CREATE FUNCTION store.check_integer(v jsonb, path text, lo numeric, hi numeric) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF jsonb_typeof(v) IS DISTINCT FROM 'number'
     OR v::numeric <> trunc(v::numeric)
     OR v::numeric < lo
     OR v::numeric > hi THEN
    PERFORM store.reject(path, format('must be an integer from %s to %s', lo, hi));
  END IF;
END
$$;

CREATE FUNCTION store.check_string(v jsonb, path text, max_length integer) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF jsonb_typeof(v) IS DISTINCT FROM 'string'
     OR length(v #>> '{}') < 1
     OR length(v #>> '{}') > max_length THEN
    PERFORM store.reject(path, format('must be a string of 1 to %s characters', max_length));
  END IF;
END
$$;

CREATE FUNCTION store.check_match(v jsonb, path text, pattern text, what text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF jsonb_typeof(v) IS DISTINCT FROM 'string' OR (v #>> '{}') !~ pattern THEN
    PERFORM store.reject(path, 'must be ' || what);
  END IF;
END
$$;

CREATE FUNCTION store.check_enum(v jsonb, path text, allowed text[]) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF jsonb_typeof(v) IS DISTINCT FROM 'string' OR (v #>> '{}') <> ALL (allowed) THEN
    PERFORM store.reject(path, 'must be one of ' || array_to_string(allowed, ', '));
  END IF;
END
$$;

-- JSON Schema's "date-time" (RFC 3339): an offset is required, T and Z may be
-- lower case, no leap second.
CREATE FUNCTION store.check_datetime(v jsonb, path text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM store.check_match(v, path,
    '^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])[Tt]([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]'
    || '(\.[0-9]+)?([Zz]|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$',
    'an RFC 3339 date-time with an offset');
  PERFORM (v #>> '{}')::timestamptz;
EXCEPTION
  WHEN datetime_field_overflow OR invalid_datetime_format THEN
    PERFORM store.reject(path, 'is not a date that exists');
END
$$;

CREATE FUNCTION store.check_nullable_datetime(v jsonb, path text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF v <> 'null'::jsonb THEN
    PERFORM store.check_datetime(v, path);
  END IF;
END
$$;

-- The schema caps counts at 2^53 - 1, which bigint holds.
CREATE FUNCTION store.check_count(v jsonb, path text, lo numeric) RETURNS void
LANGUAGE sql AS $$
  SELECT store.check_integer(v, path, lo, 9007199254740991)
$$;

CREATE FUNCTION store.check_words(v jsonb, path text, min_items integer, max_items integer)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  w record;
BEGIN
  PERFORM store.check_array(v, path, min_items, max_items);
  FOR w IN SELECT value, ordinality - 1 AS i FROM jsonb_array_elements(v) WITH ORDINALITY LOOP
    PERFORM store.check_integer(w.value, format('%s[%s]', path, w.i), 0, 65535);
  END LOOP;
END
$$;

-- The fields a reading and a missed read share.
CREATE FUNCTION store.check_event(v jsonb, path text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM store.check_object(v -> 'endpoint', path || '.endpoint', ARRAY['host', 'port']);
  PERFORM store.check_string(v -> 'endpoint' -> 'host', path || '.endpoint.host', 2147483647);
  PERFORM store.check_integer(v -> 'endpoint' -> 'port', path || '.endpoint.port', 1, 65535);
  PERFORM store.check_integer(v -> 'unit_id', path || '.unit_id', 1, 247);
  PERFORM store.check_string(v -> 'meter_serial', path || '.meter_serial', 2147483647);
  PERFORM store.check_string(v -> 'profile', path || '.profile', 2147483647);
  PERFORM store.check_string(v -> 'register_key', path || '.register_key', 2147483647);
  PERFORM store.check_datetime(v -> 'timestamp', path || '.timestamp');
END
$$;

CREATE FUNCTION store.check_reading(v jsonb, path text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM store.check_object(v, path, ARRAY[
    'endpoint', 'unit_id', 'meter_serial', 'profile', 'register_key', 'timestamp',
    'raw_words', 'value', 'unit']);
  PERFORM store.check_event(v, path);
  PERFORM store.check_words(v -> 'raw_words', path || '.raw_words', 1, 4);
  PERFORM store.check_match(v -> 'value', path || '.value', '^-?[0-9]+(\.[0-9]+)?$',
    'a decimal string such as "1234.56"');
  PERFORM store.check_enum(v -> 'unit', path || '.unit',
    enum_range(NULL::store.reading_unit)::text[]);
END
$$;

CREATE FUNCTION store.check_missed_read(v jsonb, path text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM store.check_object(v, path, ARRAY[
    'endpoint', 'unit_id', 'meter_serial', 'profile', 'register_key', 'timestamp',
    'reason', 'exception_code', 'detail', 'attempts', 'raw_words']);
  PERFORM store.check_event(v, path);
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

CREATE FUNCTION store.check_batch(b jsonb) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  e record;
BEGIN
  PERFORM store.check_object(b, 'batch', ARRAY[
    'schema_version', 'batch_id', 'sent_at', 'clock', 'backlog', 'readings', 'missed_reads']);
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
END
$$;

-- A checked batch's events as rows. Integers go through numeric: JSON may write 502.0.
CREATE FUNCTION store.batch_readings(b jsonb)
RETURNS TABLE (
  meter_serial text, register_key text, read_at timestamptz, value numeric,
  unit store.reading_unit, raw_words integer[], profile text, endpoint_host text,
  endpoint_port integer, unit_id smallint
)
LANGUAGE sql STABLE AS $$
  SELECT r ->> 'meter_serial', r ->> 'register_key', (r ->> 'timestamp')::timestamptz,
         (r ->> 'value')::numeric, (r ->> 'unit')::store.reading_unit,
         ARRAY(SELECT w::numeric::integer FROM jsonb_array_elements_text(r -> 'raw_words') w),
         r ->> 'profile', r -> 'endpoint' ->> 'host',
         (r -> 'endpoint' ->> 'port')::numeric::integer, (r ->> 'unit_id')::numeric::smallint
  FROM jsonb_array_elements(b -> 'readings') r
$$;

CREATE FUNCTION store.batch_missed_reads(b jsonb)
RETURNS TABLE (
  meter_serial text, register_key text, read_at timestamptz, reason store.missed_reason,
  exception_code smallint, detail text, attempts integer, raw_words integer[], profile text,
  endpoint_host text, endpoint_port integer, unit_id smallint
)
LANGUAGE sql STABLE AS $$
  SELECT m ->> 'meter_serial', m ->> 'register_key', (m ->> 'timestamp')::timestamptz,
         (m ->> 'reason')::store.missed_reason, (m ->> 'exception_code')::numeric::smallint,
         m ->> 'detail', (m ->> 'attempts')::numeric::integer,
         CASE WHEN m -> 'raw_words' <> 'null'::jsonb THEN
           ARRAY(SELECT w::numeric::integer FROM jsonb_array_elements_text(m -> 'raw_words') w)
         END,
         m ->> 'profile', m -> 'endpoint' ->> 'host',
         (m -> 'endpoint' ->> 'port')::numeric::integer, (m ->> 'unit_id')::numeric::smallint
  FROM jsonb_array_elements(b -> 'missed_reads') m
$$;

-- The calling collector: PostgREST runs SET ROLE to the role its token names.
-- Inside SECURITY DEFINER, current_user is the owner but the role setting is
-- still the caller's.
CREATE FUNCTION store.caller() RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT id FROM store.collectors WHERE role = current_setting('role')::name
$$;

-- Store a batch: POST /rpc/ingest with the batch as the JSON body. Answers
-- 200, 422 (schema), 409 (batch id of another collector) or 403 (not a collector).
-- contract: central/test/ingest.sql
CREATE FUNCTION api.ingest(jsonb) RETURNS jsonb
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
       endpoint_port, unit_id, collector_id, batch_id)
    SELECT r.*, caller, id FROM store.batch_readings(b) r
    ON CONFLICT (meter_serial, register_key, read_at) DO NOTHING
    RETURNING 1
  )
  SELECT count(*) INTO readings_new FROM inserted;

  WITH differing AS (
    SELECT r.*
    FROM store.batch_readings(b) r
    JOIN store.readings s USING (meter_serial, register_key, read_at)
    WHERE (s.value::text, s.unit, s.raw_words, s.profile, s.endpoint_host, s.endpoint_port, s.unit_id)
          IS DISTINCT FROM
          (r.value::text, r.unit, r.raw_words, r.profile, r.endpoint_host, r.endpoint_port, r.unit_id)
  ), kept AS (
    INSERT INTO store.reading_conflicts
      (meter_serial, register_key, read_at, value, unit, raw_words, profile, endpoint_host,
       endpoint_port, unit_id, collector_id, batch_id, received_at)
    SELECT d.*, caller, id, now() FROM differing d
    ON CONFLICT DO NOTHING
  )
  SELECT count(*) INTO readings_conflicting FROM differing;

  WITH inserted AS (
    INSERT INTO store.missed_reads
      (meter_serial, register_key, read_at, reason, exception_code, detail, attempts, raw_words,
       profile, endpoint_host, endpoint_port, unit_id, collector_id, batch_id)
    SELECT m.*, caller, id FROM store.batch_missed_reads(b) m
    ON CONFLICT (meter_serial, register_key, read_at) DO NOTHING
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

GRANT EXECUTE ON FUNCTION api.ingest(jsonb) TO collector;

-- migrate:down
-- Forward only: a rollback would drop raw data. Undo with a new migration.
