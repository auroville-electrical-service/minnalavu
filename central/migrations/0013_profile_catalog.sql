-- migrate:up

-- The profile catalog: each profile version's registers, with the decode,
-- unit and kind every reading under it takes. A reading and a missed read
-- name a profile version and a register of it, and carry neither unit nor
-- kind. A reading carries no raw words: its value is lossless (an integer
-- register's raw ÷ 10^decimals, a float's shortest round-trip decimal at its
-- width), so the words are recoverable from it and the version's decode. A
-- missed read keeps the words it got, which no decode turned into a value.
--
-- Written for an empty store: readings stored without a profile version
-- cannot be given one, so a store holding any is rebuilt, not migrated.
DO $$
BEGIN
  IF EXISTS (SELECT FROM store.readings) OR EXISTS (SELECT FROM store.reading_conflicts)
     OR EXISTS (SELECT FROM store.missed_reads) THEN
    RAISE EXCEPTION 'this migration needs a store with no readings or missed reads'
      USING HINT = 'Rebuild the store: a new database, every migration, then bin/load-profiles.';
  END IF;
END
$$;

-- The names contract/profiles allows.
CREATE TYPE store.register_table AS ENUM ('holding', 'input');
CREATE TYPE store.register_type AS ENUM ('u16', 'i16', 'u32', 'i32', 'u64', 'f32', 'f64');
CREATE TYPE store.word_order AS ENUM ('high_first', 'low_first');
CREATE TYPE store.register_kind AS ENUM ('cumulative', 'interval', 'demand', 'instantaneous');

-- contract: central/test/profiles.sql
CREATE TABLE store.profile_versions (
  profile text NOT NULL CHECK (profile ~ '^[a-z][a-z0-9_]{0,39}$'),
  version bigint NOT NULL CHECK (version BETWEEN 1 AND 9007199254740991),
  loaded_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (profile, version)
);
COMMENT ON TABLE store.profile_versions IS
  'Each profile version loaded from contract/profiles by bin/load-profiles. A version never changes; a correction is a new version.';

-- contract: central/test/profiles.sql
CREATE TABLE store.profile_registers (
  profile text NOT NULL,
  version bigint NOT NULL,
  register_key text NOT NULL CHECK (register_key <> ''),
  register_table store.register_table NOT NULL,
  address integer NOT NULL CHECK (address BETWEEN 0 AND 65535),
  type store.register_type NOT NULL,
  word_order store.word_order NOT NULL,
  decimals smallint CHECK (decimals BETWEEN 0 AND 9),
  unit store.reading_unit NOT NULL,
  kind store.register_kind NOT NULL,
  PRIMARY KEY (profile, version, register_key),
  FOREIGN KEY (profile, version) REFERENCES store.profile_versions (profile, version),
  CONSTRAINT profile_registers_decimals
    CHECK ((type IN ('f32', 'f64')) = (decimals IS NULL))
);
COMMENT ON COLUMN store.profile_registers.decimals IS
  'An integer register''s value is raw ÷ 10^decimals; a float register has none.';

DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['profile_versions', 'profile_registers'] LOOP
    EXECUTE format(
      'CREATE TRIGGER refuse_change BEFORE UPDATE OR DELETE ON store.%I
         FOR EACH ROW EXECUTE FUNCTION store.refuse_change()', t);
    EXECUTE format(
      'CREATE TRIGGER refuse_truncate BEFORE TRUNCATE ON store.%I
         FOR EACH STATEMENT EXECUTE FUNCTION store.refuse_change()', t);
  END LOOP;
END
$$;

-- contract: central/test/ingest.sql
ALTER TABLE store.readings
  DROP COLUMN raw_words,
  DROP COLUMN unit,
  ADD COLUMN profile_version bigint NOT NULL,
  ADD CONSTRAINT readings_profile_register FOREIGN KEY (profile, profile_version, register_key)
    REFERENCES store.profile_registers (profile, version, register_key);
ALTER TABLE store.reading_conflicts
  DROP COLUMN raw_words,
  DROP COLUMN unit,
  ADD COLUMN profile_version bigint NOT NULL,
  ADD CONSTRAINT reading_conflicts_profile_register
    FOREIGN KEY (profile, profile_version, register_key)
    REFERENCES store.profile_registers (profile, version, register_key);
ALTER TABLE store.missed_reads
  ADD COLUMN profile_version bigint NOT NULL,
  ADD CONSTRAINT missed_reads_profile_register FOREIGN KEY (profile, profile_version, register_key)
    REFERENCES store.profile_registers (profile, version, register_key);
COMMENT ON COLUMN store.readings.value IS
  'As sent, scale included: unrounded, in the unit of its profile version''s register.';
COMMENT ON COLUMN store.missed_reads.raw_words IS
  'The words read, where some were and no value came of them (reason decode); else NULL.';

-- A profile file's registers as catalog rows, at its version.
CREATE FUNCTION store.profile_document_registers(document jsonb, version bigint)
RETURNS SETOF store.profile_registers
LANGUAGE sql IMMUTABLE AS $$
  SELECT document ->> 'profile', version, r ->> 'key', (r ->> 'table')::store.register_table,
         (r ->> 'address')::integer, (r ->> 'type')::store.register_type,
         (r ->> 'word_order')::store.word_order, (r ->> 'decimals')::smallint,
         (r ->> 'unit')::store.reading_unit, (r ->> 'kind')::store.register_kind
  FROM jsonb_array_elements(document -> 'registers') r
$$;

-- Load one profile file's version into the catalog, as the owner. A version
-- already loaded is left as it is when the file names the same registers
-- with the same decode, table, address, unit and kind, and refused (22023)
-- otherwise. Returns 'new' or 'already loaded'. Run by bin/load-profiles.
-- contract: central/test/profiles.sql
CREATE FUNCTION admin.load_profile(document jsonb) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
  p text := document ->> 'profile';
  v bigint;
  differing text;
BEGIN
  IF jsonb_typeof(document -> 'version') IS DISTINCT FROM 'number'
     OR (document -> 'version')::numeric <> trunc((document -> 'version')::numeric) THEN
    RAISE SQLSTATE '22023' USING MESSAGE = format('profile %s: version must be an integer', p);
  END IF;
  IF jsonb_typeof(document -> 'registers') IS DISTINCT FROM 'array'
     OR jsonb_array_length(document -> 'registers') = 0 THEN
    RAISE SQLSTATE '22023' USING MESSAGE = format('profile %s: registers must be a non-empty list', p);
  END IF;
  v := (document -> 'version')::numeric;

  IF NOT EXISTS (SELECT FROM store.profile_versions WHERE profile = p AND version = v) THEN
    INSERT INTO store.profile_versions (profile, version) VALUES (p, v);
    INSERT INTO store.profile_registers SELECT * FROM store.profile_document_registers(document, v);
    RETURN 'new';
  END IF;

  WITH loading AS (
    SELECT * FROM store.profile_document_registers(document, v)
  ), loaded AS (
    SELECT * FROM store.profile_registers r WHERE r.profile = p AND r.version = v
  )
  SELECT string_agg(DISTINCT coalesce(d.register_key, '(no key)'), ', ') INTO differing
  FROM ((SELECT * FROM loading EXCEPT ALL SELECT * FROM loaded)
        UNION ALL
        (SELECT * FROM loaded EXCEPT ALL SELECT * FROM loading)) d;
  IF differing IS NOT NULL THEN
    RAISE SQLSTATE '22023' USING
      MESSAGE = format('profile %s version %s is already loaded with other registers: %s',
                       p, v, differing),
      HINT = 'A loaded version never changes: give the profile a new version.';
  END IF;
  RETURN 'already loaded';
END
$$;

-- The fields a reading and a missed read share; the serial is checked by each.
-- contract: central/test/schema.sql
CREATE OR REPLACE FUNCTION store.check_event(v jsonb, path text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM store.check_object(v -> 'endpoint', path || '.endpoint', ARRAY['host', 'port']);
  PERFORM store.check_string(v -> 'endpoint' -> 'host', path || '.endpoint.host', 2147483647);
  PERFORM store.check_integer(v -> 'endpoint' -> 'port', path || '.endpoint.port', 1, 65535);
  PERFORM store.check_integer(v -> 'unit_id', path || '.unit_id', 1, 247);
  PERFORM store.check_string(v -> 'profile', path || '.profile', 2147483647);
  PERFORM store.check_count(v -> 'profile_version', path || '.profile_version', 1);
  PERFORM store.check_string(v -> 'register_key', path || '.register_key', 2147483647);
  PERFORM store.check_datetime(v -> 'timestamp', path || '.timestamp');
END
$$;

-- contract: central/test/schema.sql
CREATE OR REPLACE FUNCTION store.check_reading(v jsonb, path text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM store.check_object(v, path, ARRAY[
    'endpoint', 'unit_id', 'meter_serial', 'product_code', 'profile', 'profile_version',
    'register_key', 'timestamp', 'value'], ARRAY['request_id']);
  PERFORM store.check_event(v, path);
  PERFORM store.check_string(v -> 'meter_serial', path || '.meter_serial', 2147483647);
  PERFORM store.check_string(v -> 'product_code', path || '.product_code', 2147483647);
  PERFORM store.check_match(v -> 'value', path || '.value', '^-?[0-9]+(\.[0-9]+)?$',
    'a decimal string such as "1234.56"');
  IF v ? 'request_id' THEN
    PERFORM store.check_uuid(v -> 'request_id', path || '.request_id');
  END IF;
END
$$;

-- contract: central/test/schema.sql
CREATE OR REPLACE FUNCTION store.check_missed_read(v jsonb, path text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM store.check_object(v, path, ARRAY[
    'endpoint', 'unit_id', 'meter_serial', 'profile', 'profile_version', 'register_key',
    'timestamp', 'reason', 'exception_code', 'detail', 'attempts', 'raw_words'],
    ARRAY['request_id']);
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
  IF v ? 'request_id' THEN
    PERFORM store.check_uuid(v -> 'request_id', path || '.request_id');
  END IF;
END
$$;

-- A checked batch's readings and missed reads against the catalog. An event
-- under a profile version the store has not loaded is refused with 503, so
-- the collector keeps the batch and sends it again once the version is
-- loaded; one naming a register its version does not name, with 422.
-- contract: central/test/ingest.sql
CREATE FUNCTION store.check_catalog(b jsonb) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  e record;
BEGIN
  FOR e IN
    SELECT kind, i, x ->> 'profile' AS profile, (x ->> 'profile_version')::numeric::bigint AS version,
           x ->> 'register_key' AS register_key
    FROM (SELECT 'readings' AS kind, ordinality - 1 AS i, value AS x
          FROM jsonb_array_elements(b -> 'readings') WITH ORDINALITY
          UNION ALL
          SELECT 'missed_reads', ordinality - 1, value
          FROM jsonb_array_elements(b -> 'missed_reads') WITH ORDINALITY) events
    WHERE NOT EXISTS (
      SELECT FROM store.profile_registers r
      WHERE (r.profile, r.version, r.register_key)
            = (x ->> 'profile', (x ->> 'profile_version')::numeric::bigint, x ->> 'register_key'))
    ORDER BY kind DESC, i
  LOOP
    IF NOT EXISTS (SELECT FROM store.profile_versions v
                   WHERE (v.profile, v.version) = (e.profile, e.version)) THEN
      RAISE SQLSTATE 'PT503' USING
        MESSAGE = format('batch.%s[%s]: profile %s version %s is not loaded in the store',
                         e.kind, e.i, e.profile, e.version),
        HINT = 'Load it with central/bin/load-profiles; the batch is accepted once it is.';
    END IF;
    PERFORM store.reject(format('batch.%s[%s].register_key', e.kind, e.i),
      format('is not a register of profile %s version %s', e.profile, e.version));
  END LOOP;
END
$$;

-- Their results change, which CREATE OR REPLACE cannot do.
DROP FUNCTION store.batch_readings(jsonb);
CREATE FUNCTION store.batch_readings(b jsonb)
RETURNS TABLE (
  meter_serial text, register_key text, read_at timestamptz, value numeric, profile text,
  profile_version bigint, endpoint_host text, endpoint_port integer, unit_id smallint,
  product_code text
)
LANGUAGE sql STABLE AS $$
  SELECT r ->> 'meter_serial', r ->> 'register_key', (r ->> 'timestamp')::timestamptz,
         (r ->> 'value')::numeric, r ->> 'profile', (r ->> 'profile_version')::numeric::bigint,
         r -> 'endpoint' ->> 'host', (r -> 'endpoint' ->> 'port')::numeric::integer,
         (r ->> 'unit_id')::numeric::smallint, r ->> 'product_code'
  FROM jsonb_array_elements(b -> 'readings') r
$$;

DROP FUNCTION store.batch_missed_reads(jsonb);
CREATE FUNCTION store.batch_missed_reads(b jsonb)
RETURNS TABLE (
  meter_serial text, register_key text, read_at timestamptz, reason store.missed_reason,
  exception_code smallint, detail text, attempts integer, raw_words integer[], profile text,
  profile_version bigint, endpoint_host text, endpoint_port integer, unit_id smallint
)
LANGUAGE sql STABLE AS $$
  SELECT m ->> 'meter_serial', m ->> 'register_key', (m ->> 'timestamp')::timestamptz,
         (m ->> 'reason')::store.missed_reason, (m ->> 'exception_code')::numeric::smallint,
         m ->> 'detail', (m ->> 'attempts')::numeric::integer,
         CASE WHEN m -> 'raw_words' <> 'null'::jsonb THEN
           ARRAY(SELECT w::numeric::integer FROM jsonb_array_elements_text(m -> 'raw_words') w)
         END,
         m ->> 'profile', (m ->> 'profile_version')::numeric::bigint,
         m -> 'endpoint' ->> 'host', (m -> 'endpoint' ->> 'port')::numeric::integer,
         (m ->> 'unit_id')::numeric::smallint
  FROM jsonb_array_elements(b -> 'missed_reads') m
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
      'conflicting', firmware_conflicting))
    || jsonb_strip_nulls(jsonb_build_object(
         'jobs', jobs.pending(caller),
         'unknown_requests', to_jsonb(unknown_requests)));
END
$$;

-- migrate:down
-- Forward only: a rollback would drop raw data. Undo with a new migration.
