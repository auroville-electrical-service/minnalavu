-- migrate:up

-- Reads on demand, asked for by minkanakku's staff side. A request names a
-- collector, the meters (by serial, as the registry identifies them) and a
-- kind, never an address; who asked is an opaque reference minkanakku
-- resolves. Requests and their links to what came of them are a record: rows
-- are only ever added. A request's state is derived from its links and the
-- clock, in jobs.request_status.
-- contract: central/test/requests.sql

DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'minkanakku_staff') THEN
    -- A group role: logins are members of it (central/README.md).
    CREATE ROLE minkanakku_staff NOLOGIN;
  END IF;
END
$$;

CREATE SCHEMA jobs;
COMMENT ON SCHEMA jobs IS
  'Requests for jobs a collector runs. minkanakku_staff may call jobs.request_job and read jobs.request_status, and nothing else.';
GRANT USAGE ON SCHEMA jobs TO minkanakku_staff;

-- Only read_on_demand may be requested; later kinds are scheduled, never requested.
CREATE TYPE jobs.kind AS ENUM ('read_on_demand');
CREATE TYPE jobs.state AS ENUM ('pending', 'answered', 'expired');

CREATE TABLE jobs.requests (
  request_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  collector_id text NOT NULL REFERENCES store.collectors (id),
  kind jobs.kind NOT NULL,
  requester text NOT NULL CHECK (requester ~ '^[^[:cntrl:]]{1,200}$'),
  requested_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  CHECK (expires_at > requested_at)
);
COMMENT ON COLUMN jobs.requests.requester IS
  'Who asked, as an opaque reference minkanakku resolves; nothing about the person.';
COMMENT ON COLUMN jobs.requests.expires_at IS
  'After this, a request not yet answered is no longer offered to its collector.';
CREATE INDEX ON jobs.requests (collector_id, expires_at);

CREATE TABLE jobs.request_meters (
  request_id uuid NOT NULL REFERENCES jobs.requests (request_id),
  serial text NOT NULL REFERENCES registry.meters (serial),
  PRIMARY KEY (request_id, serial)
);

-- A reading a collector sent for a request, by the readings key. The reading
-- itself is stored as any other; this row is the link, so the raw row is
-- never touched, and a resend links nothing twice.
CREATE TABLE jobs.request_readings (
  request_id uuid NOT NULL REFERENCES jobs.requests (request_id),
  meter_serial text NOT NULL,
  register_key text NOT NULL,
  read_at timestamptz NOT NULL,
  batch_id uuid NOT NULL REFERENCES store.batches (batch_id),
  linked_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (request_id, meter_serial, register_key, read_at)
);

-- A missed read a collector sent for a request, by the missed reads key.
CREATE TABLE jobs.request_missed_reads (
  request_id uuid NOT NULL REFERENCES jobs.requests (request_id),
  collector_id text NOT NULL REFERENCES store.collectors (id),
  endpoint_host text NOT NULL,
  endpoint_port integer NOT NULL,
  unit_id smallint NOT NULL,
  register_key text NOT NULL,
  read_at timestamptz NOT NULL,
  batch_id uuid NOT NULL REFERENCES store.batches (batch_id),
  linked_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (request_id, collector_id, endpoint_host, endpoint_port, unit_id, register_key,
               read_at)
);

CREATE FUNCTION jobs.refuse_change() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '% on %.% refused: requests are a record and are never changed or deleted',
    TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME;
END
$$;

DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['requests', 'request_meters', 'request_readings', 'request_missed_reads'] LOOP
    EXECUTE format(
      'CREATE TRIGGER refuse_change BEFORE UPDATE OR DELETE ON jobs.%I
         FOR EACH ROW EXECUTE FUNCTION jobs.refuse_change()', t);
    EXECUTE format(
      'CREATE TRIGGER refuse_truncate BEFORE TRUNCATE ON jobs.%I
         FOR EACH STATEMENT EXECUTE FUNCTION jobs.refuse_change()', t);
  END LOOP;
END
$$;

-- Each request as of now(): answered once any reading or missed read has come
-- for it (whenever that is, so a late answer still counts); else expired once
-- expires_at has passed; else pending. answered_at is when the first came.
-- contract: central/test/requests.sql
CREATE VIEW jobs.request_status AS
  SELECT q.request_id, q.collector_id, q.kind, m.meters, q.requester, q.requested_at,
         q.expires_at, r.readings, x.missed_reads,
         least(r.first_linked_at, x.first_linked_at) AS answered_at,
         CASE
           WHEN r.readings > 0 OR x.missed_reads > 0 THEN 'answered'
           WHEN now() >= q.expires_at THEN 'expired'
           ELSE 'pending'
         END::jobs.state AS state
  FROM jobs.requests q
  CROSS JOIN LATERAL (
    SELECT array_agg(rm.serial ORDER BY rm.serial) AS meters
    FROM jobs.request_meters rm WHERE rm.request_id = q.request_id
  ) m
  CROSS JOIN LATERAL (
    SELECT count(*) AS readings, min(l.linked_at) AS first_linked_at
    FROM jobs.request_readings l WHERE l.request_id = q.request_id
  ) r
  CROSS JOIN LATERAL (
    SELECT count(*) AS missed_reads, min(l.linked_at) AS first_linked_at
    FROM jobs.request_missed_reads l WHERE l.request_id = q.request_id
  ) x;
GRANT SELECT ON jobs.request_status TO minkanakku_staff;

-- Ask a collector to read meters now, as minkanakku_staff. Inserts the request
-- and touches nothing else; minkanakku rings the collector's doorbell itself.
-- Each meter must be in service now on an endpoint in service now with that
-- collector, which no other system polls. Refused with 22023 otherwise. A
-- request not answered within an hour expires.
--   SELECT jobs.request_job(collector_id => 'pilot_01', kind => 'read_on_demand',
--     meters => ARRAY['…'], requester => '…');
-- contract: central/test/requests.sql
CREATE FUNCTION jobs.request_job(collector_id text, kind text, meters text[], requester text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
#variable_conflict use_variable
DECLARE
  id uuid;
  strays text;
BEGIN
  IF kind IS DISTINCT FROM 'read_on_demand' THEN
    RAISE SQLSTATE '22023' USING
      MESSAGE = format('kind %s cannot be requested: only read_on_demand can',
        coalesce(kind, '(none)'));
  END IF;
  IF NOT EXISTS (SELECT FROM store.collectors c WHERE c.id = collector_id) THEN
    RAISE SQLSTATE '22023' USING
      MESSAGE = format('collector %s is not registered', collector_id);
  END IF;
  IF requester IS NULL OR requester !~ '^[^[:cntrl:]]{1,200}$' THEN
    RAISE SQLSTATE '22023' USING
      MESSAGE = 'requester must be 1 to 200 characters with no control characters';
  END IF;
  IF coalesce(cardinality(meters), 0) = 0 OR array_position(meters, NULL) IS NOT NULL
     OR cardinality(meters) <> (SELECT count(DISTINCT s) FROM unnest(meters) s) THEN
    RAISE SQLSTATE '22023' USING
      MESSAGE = 'meters must name at least one serial, each once, and no NULL';
  END IF;

  SELECT string_agg(s, ', ' ORDER BY s) INTO strays
  FROM unnest(meters) s
  WHERE NOT EXISTS (
    SELECT FROM registry.meter_history m
    JOIN registry.endpoint_history e ON e.endpoint_id = m.endpoint_id AND e.period @> now()
    WHERE m.serial = s AND m.period @> now() AND m.in_service AND e.in_service
      AND e.collector_id = collector_id AND NOT e.polled_by_other_system);
  IF strays IS NOT NULL THEN
    RAISE SQLSTATE '22023' USING
      MESSAGE = format('meters not polled by collector %s now: %s', collector_id, strays);
  END IF;

  INSERT INTO jobs.requests (collector_id, kind, requester, expires_at)
  VALUES (collector_id, 'read_on_demand', requester, now() + interval '1 hour')
  RETURNING request_id INTO id;
  INSERT INTO jobs.request_meters (request_id, serial) SELECT id, s FROM unnest(meters) s;
  RETURN id;
END
$$;
GRANT EXECUTE ON FUNCTION jobs.request_job(text, text, text[], text) TO minkanakku_staff;

-- A collector's requests neither answered nor expired, oldest first, as the
-- ingest answer lists them; NULL when there are none.
CREATE FUNCTION jobs.pending(collector text) RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_agg(jsonb_build_object(
           'request_id', q.request_id, 'kind', q.kind,
           'meters', (SELECT jsonb_agg(rm.serial ORDER BY rm.serial)
                      FROM jobs.request_meters rm WHERE rm.request_id = q.request_id),
           'requested_at', q.requested_at, 'expires_at', q.expires_at)
         ORDER BY q.requested_at, q.request_id)
  FROM jobs.requests q
  WHERE q.collector_id = collector AND q.expires_at > now()
    AND NOT EXISTS (SELECT FROM jobs.request_readings l WHERE l.request_id = q.request_id)
    AND NOT EXISTS (SELECT FROM jobs.request_missed_reads l WHERE l.request_id = q.request_id)
$$;

-- A UUID as JSON Schema's "uuid" format accepts it.
CREATE FUNCTION store.check_uuid(v jsonb, path text) RETURNS void
LANGUAGE sql AS $$
  SELECT store.check_match(v, path,
    '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$', 'a UUID')
$$;

-- contract: central/test/schema.sql
CREATE OR REPLACE FUNCTION store.check_reading(v jsonb, path text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM store.check_object(v, path, ARRAY[
    'endpoint', 'unit_id', 'meter_serial', 'product_code', 'profile', 'register_key',
    'timestamp', 'raw_words', 'value', 'unit'], ARRAY['request_id']);
  PERFORM store.check_event(v, path);
  PERFORM store.check_string(v -> 'meter_serial', path || '.meter_serial', 2147483647);
  PERFORM store.check_string(v -> 'product_code', path || '.product_code', 2147483647);
  PERFORM store.check_words(v -> 'raw_words', path || '.raw_words', 1, 4);
  PERFORM store.check_match(v -> 'value', path || '.value', '^-?[0-9]+(\.[0-9]+)?$',
    'a decimal string such as "1234.56"');
  PERFORM store.check_enum(v -> 'unit', path || '.unit',
    enum_range(NULL::store.reading_unit)::text[]);
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
    'endpoint', 'unit_id', 'meter_serial', 'profile', 'register_key', 'timestamp',
    'reason', 'exception_code', 'detail', 'attempts', 'raw_words'], ARRAY['request_id']);
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

-- A checked batch's readings and missed reads that carry a request id, by
-- their keys; none when none do.
CREATE FUNCTION jobs.batch_links(b jsonb)
RETURNS TABLE (
  request_id uuid, is_reading boolean, meter_serial text, endpoint_host text,
  endpoint_port integer, unit_id smallint, register_key text, read_at timestamptz
)
LANGUAGE sql STABLE AS $$
  SELECT (r ->> 'request_id')::uuid, true, r ->> 'meter_serial', NULL, NULL, NULL,
         r ->> 'register_key', (r ->> 'timestamp')::timestamptz
  FROM jsonb_array_elements(b -> 'readings') r WHERE r ? 'request_id'
  UNION ALL
  SELECT (m ->> 'request_id')::uuid, false, NULL, m -> 'endpoint' ->> 'host',
         (m -> 'endpoint' ->> 'port')::numeric::integer, (m ->> 'unit_id')::numeric::smallint,
         m ->> 'register_key', (m ->> 'timestamp')::timestamptz
  FROM jsonb_array_elements(b -> 'missed_reads') m WHERE m ? 'request_id'
$$;

-- Link a checked batch's readings and missed reads that carry a request id to
-- the calling collector's request, once each, and notify request_answered for
-- each request that gained a link; the notice goes out when the batch
-- commits. Returns the request ids in the batch that are not the caller's
-- requests, sorted, or NULL: their readings and missed reads are stored as any
-- other, unlinked.
-- contract: central/test/requests.sql
CREATE FUNCTION jobs.link_batch(b jsonb, caller text, batch uuid) RETURNS uuid[]
LANGUAGE plpgsql AS $$
DECLARE
  unknown uuid[];
  notified bigint;
BEGIN
  SELECT array_agg(DISTINCT l.request_id ORDER BY l.request_id) INTO unknown
  FROM jobs.batch_links(b) l
  WHERE NOT EXISTS (SELECT FROM jobs.requests q
                    WHERE q.request_id = l.request_id AND q.collector_id = caller);

  WITH ours AS (
    SELECT l.* FROM jobs.batch_links(b) l
    JOIN jobs.requests q ON q.request_id = l.request_id AND q.collector_id = caller
  ), readings AS (
    INSERT INTO jobs.request_readings (request_id, meter_serial, register_key, read_at, batch_id)
    SELECT o.request_id, o.meter_serial, o.register_key, o.read_at, batch
    FROM ours o WHERE o.is_reading
    ON CONFLICT DO NOTHING
    RETURNING request_id
  ), missed AS (
    INSERT INTO jobs.request_missed_reads
      (request_id, collector_id, endpoint_host, endpoint_port, unit_id, register_key, read_at,
       batch_id)
    SELECT o.request_id, caller, o.endpoint_host, o.endpoint_port, o.unit_id, o.register_key,
           o.read_at, batch
    FROM ours o WHERE NOT o.is_reading
    ON CONFLICT DO NOTHING
    RETURNING request_id
  ), linked AS (
    SELECT n.request_id, count(*) FILTER (WHERE n.is_reading) AS readings,
           count(*) FILTER (WHERE NOT n.is_reading) AS missed_reads
    FROM (SELECT r.request_id, true AS is_reading FROM readings r
          UNION ALL SELECT m.request_id, false FROM missed m) n
    GROUP BY n.request_id
  )
  SELECT count(*) INTO notified
  FROM (SELECT pg_notify('request_answered', jsonb_build_object(
                 'request_id', k.request_id, 'batch_id', batch,
                 'readings', k.readings, 'missed_reads', k.missed_reads)::text)
        FROM linked k) n;

  RETURN unknown;
END
$$;

-- Store a batch: POST /rpc/ingest with the batch as the JSON body. Answers
-- 200, 422 (schema), 409 (batch id of another collector) or 403 (not a
-- collector). A batch with no readings or missed reads is a heartbeat; its
-- answer, like every answer, lists the collector's pending jobs.
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
