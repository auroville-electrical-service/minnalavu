-- migrate:up

-- Copied stored entries and meter-clock reads, as batch.v1 carries them.
-- An entry is the meter's own record, keyed by the meter's stamp, never by
-- the slot it was read at: (meter_serial, store, register_key, meter_time).
-- Its quantity is one of its profile version's stored quantities (a foreign
-- key to the catalog), so its unit and kind are the catalog's, and only a
-- quantity the catalog holds in that store is ever stored there.

-- contract: central/test/stored.sql
CREATE TABLE store.stored_entries (
  meter_serial text NOT NULL,
  store store.stored_store NOT NULL,
  register_key text NOT NULL,
  meter_time timestamp NOT NULL,
  value numeric NOT NULL,
  interval_s integer CHECK (interval_s BETWEEN 1 AND 86400),
  profile text NOT NULL,
  profile_version bigint NOT NULL,
  product_code text NOT NULL,
  slot integer NOT NULL CHECK (slot BETWEEN 0 AND 65535),
  copied_at timestamptz NOT NULL,
  request_id uuid,
  endpoint_host text NOT NULL,
  endpoint_port integer NOT NULL,
  unit_id smallint NOT NULL,
  collector_id text NOT NULL REFERENCES store.collectors (id),
  batch_id uuid NOT NULL REFERENCES store.batches (batch_id),
  CONSTRAINT stored_entries_key UNIQUE (meter_serial, store, register_key, meter_time),
  CONSTRAINT stored_entries_interval CHECK ((store = 'load_survey') = (interval_s IS NOT NULL)),
  CONSTRAINT stored_entries_profile_stored FOREIGN KEY (profile, profile_version, store, register_key)
    REFERENCES store.profile_stored (profile, version, store, register_key)
);
COMMENT ON COLUMN store.stored_entries.meter_time IS
  'The meter''s own stamp, decoded per the profile version: its local time, no zone. A load-survey entry''s is its interval''s start.';
COMMENT ON COLUMN store.stored_entries.value IS
  'As sent: unrounded, in the unit of its profile version''s stored quantity.';
COMMENT ON COLUMN store.stored_entries.slot IS
  'The selector value it was read at: evidence of the copy, never part of the key.';
COMMENT ON COLUMN store.stored_entries.copied_at IS
  'The collector''s clock when the reply arrived; see the batch''s clock_source.';
COMMENT ON COLUMN store.stored_entries.request_id IS
  'The request the entry was copied for, as first sent; no request kind asks for a copy, so nothing links it.';
SELECT create_hypertable('store.stored_entries', by_range('meter_time', INTERVAL '7 days'));
-- For entries by the batch that brought them: late copies by arrival.
CREATE INDEX ON store.stored_entries (batch_id);

-- An entry whose key is taken by one that says something else.
-- contract: central/test/stored.sql
CREATE TABLE store.stored_entry_conflicts (
  LIKE store.stored_entries INCLUDING CONSTRAINTS,
  received_at timestamptz NOT NULL,
  PRIMARY KEY (batch_id, meter_serial, store, register_key, meter_time),
  FOREIGN KEY (collector_id) REFERENCES store.collectors (id),
  FOREIGN KEY (batch_id) REFERENCES store.batches (batch_id),
  FOREIGN KEY (profile, profile_version, store, register_key)
    REFERENCES store.profile_stored (profile, version, store, register_key)
);

-- A meter's clock as read beside the collector's, raw. Keyed as a firmware
-- read is, by where and when the collector read it: a resent read is a
-- duplicate, and one that says otherwise is kept as a conflict. Offsets are
-- views, grounded through the collector's clock checks.
-- contract: central/test/stored.sql
CREATE TABLE store.meter_clock_reads (
  collector_id text NOT NULL REFERENCES store.collectors (id),
  endpoint_host text NOT NULL,
  endpoint_port integer NOT NULL,
  unit_id smallint NOT NULL,
  collector_at timestamptz NOT NULL,
  meter_serial text NOT NULL,
  profile text NOT NULL,
  profile_version bigint NOT NULL,
  meter_time timestamp NOT NULL,
  batch_id uuid NOT NULL REFERENCES store.batches (batch_id),
  PRIMARY KEY (collector_id, endpoint_host, endpoint_port, unit_id, collector_at),
  FOREIGN KEY (profile, profile_version) REFERENCES store.profile_versions (profile, version)
);
COMMENT ON COLUMN store.meter_clock_reads.collector_at IS
  'The collector''s clock when the meter''s clock was read; see the batch''s clock_source.';
COMMENT ON COLUMN store.meter_clock_reads.meter_time IS
  'The meter''s clock as it read, decoded per the profile version: its local time, no zone.';
CREATE INDEX ON store.meter_clock_reads (meter_serial, collector_at DESC);
CREATE INDEX ON store.meter_clock_reads (batch_id);

-- A meter-clock read whose key is taken by one that says something else.
-- contract: central/test/stored.sql
CREATE TABLE store.meter_clock_read_conflicts (
  LIKE store.meter_clock_reads INCLUDING CONSTRAINTS,
  received_at timestamptz NOT NULL,
  PRIMARY KEY (batch_id, collector_id, endpoint_host, endpoint_port, unit_id, collector_at),
  FOREIGN KEY (collector_id) REFERENCES store.collectors (id),
  FOREIGN KEY (batch_id) REFERENCES store.batches (batch_id),
  FOREIGN KEY (profile, profile_version) REFERENCES store.profile_versions (profile, version)
);

DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['stored_entries', 'stored_entry_conflicts', 'meter_clock_reads',
                           'meter_clock_read_conflicts'] LOOP
    EXECUTE format(
      'CREATE TRIGGER refuse_change BEFORE UPDATE OR DELETE ON store.%I
         FOR EACH ROW EXECUTE FUNCTION store.refuse_change()', t);
    EXECUTE format(
      'CREATE TRIGGER refuse_truncate BEFORE TRUNCATE ON store.%I
         FOR EACH STATEMENT EXECUTE FUNCTION store.refuse_change()', t);
  END LOOP;
END
$$;

-- Counted per upload as readings are; an upload received before these were
-- stored counts none.
-- contract: central/test/stored.sql
ALTER TABLE store.uploads
  ADD COLUMN stored_entries_inserted integer NOT NULL DEFAULT 0,
  ADD COLUMN stored_entries_duplicate integer NOT NULL DEFAULT 0,
  ADD COLUMN stored_entries_conflicting integer NOT NULL DEFAULT 0,
  ADD COLUMN meter_clock_reads_inserted integer NOT NULL DEFAULT 0,
  ADD COLUMN meter_clock_reads_duplicate integer NOT NULL DEFAULT 0,
  ADD COLUMN meter_clock_reads_conflicting integer NOT NULL DEFAULT 0;
ALTER TABLE store.uploads
  ALTER COLUMN stored_entries_inserted DROP DEFAULT,
  ALTER COLUMN stored_entries_duplicate DROP DEFAULT,
  ALTER COLUMN stored_entries_conflicting DROP DEFAULT,
  ALTER COLUMN meter_clock_reads_inserted DROP DEFAULT,
  ALTER COLUMN meter_clock_reads_duplicate DROP DEFAULT,
  ALTER COLUMN meter_clock_reads_conflicting DROP DEFAULT;

-- A checked batch's stored entries and meter-clock reads against the catalog.
-- One under a profile version the store has not loaded is refused with 503,
-- as a reading is; an entry whose quantity its version does not hold in its
-- store, with 422.
-- contract: central/test/stored.sql
CREATE FUNCTION store.check_copied_catalog(b jsonb) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  e record;
BEGIN
  FOR e IN
    SELECT kind, i, x ->> 'profile' AS profile, (x ->> 'profile_version')::numeric::bigint AS version,
           x ->> 'store' AS store, x ->> 'register_key' AS register_key
    FROM (SELECT 'stored_entries' AS kind, ordinality - 1 AS i, value AS x
          FROM jsonb_array_elements(coalesce(b -> 'stored_entries', '[]')) WITH ORDINALITY
          UNION ALL
          SELECT 'meter_clock_reads', ordinality - 1, value
          FROM jsonb_array_elements(coalesce(b -> 'meter_clock_reads', '[]')) WITH ORDINALITY) events
    WHERE NOT EXISTS (
      SELECT FROM store.profile_stored s
      WHERE (s.profile, s.version, s.store::text, s.register_key)
            = (x ->> 'profile', (x ->> 'profile_version')::numeric::bigint, x ->> 'store',
               x ->> 'register_key'))
    ORDER BY kind DESC, i
  LOOP
    IF NOT EXISTS (SELECT FROM store.profile_versions v
                   WHERE (v.profile, v.version) = (e.profile, e.version)) THEN
      RAISE SQLSTATE 'PT503' USING
        MESSAGE = format('batch.%s[%s]: profile %s version %s is not loaded in the store',
                         e.kind, e.i, e.profile, e.version),
        HINT = 'Load it with central/bin/load-profiles; the batch is accepted once it is.';
    END IF;
    IF e.kind = 'stored_entries' THEN
      PERFORM store.reject(format('batch.%s[%s].register_key', e.kind, e.i),
        format('is not a %s quantity of profile %s version %s', e.store, e.profile, e.version));
    END IF;
  END LOOP;
END
$$;

-- A checked batch's stored entries and meter-clock reads as rows; none when
-- it carries none.
CREATE FUNCTION store.batch_stored_entries(b jsonb)
RETURNS TABLE (
  meter_serial text, store store.stored_store, register_key text, meter_time timestamp,
  value numeric, interval_s integer, profile text, profile_version bigint, product_code text,
  slot integer, copied_at timestamptz, request_id uuid, endpoint_host text,
  endpoint_port integer, unit_id smallint
)
LANGUAGE sql STABLE AS $$
  SELECT e ->> 'meter_serial', (e ->> 'store')::store.stored_store, e ->> 'register_key',
         (e ->> 'meter_time')::timestamp, (e ->> 'value')::numeric,
         (e ->> 'interval_s')::numeric::integer, e ->> 'profile',
         (e ->> 'profile_version')::numeric::bigint, e ->> 'product_code',
         (e ->> 'slot')::numeric::integer, (e ->> 'copied_at')::timestamptz,
         (e ->> 'request_id')::uuid, e -> 'endpoint' ->> 'host',
         (e -> 'endpoint' ->> 'port')::numeric::integer, (e ->> 'unit_id')::numeric::smallint
  FROM jsonb_array_elements(coalesce(b -> 'stored_entries', '[]')) e
$$;

CREATE FUNCTION store.batch_meter_clock_reads(b jsonb)
RETURNS TABLE (
  endpoint_host text, endpoint_port integer, unit_id smallint, collector_at timestamptz,
  meter_serial text, profile text, profile_version bigint, meter_time timestamp
)
LANGUAGE sql STABLE AS $$
  SELECT m -> 'endpoint' ->> 'host', (m -> 'endpoint' ->> 'port')::numeric::integer,
         (m ->> 'unit_id')::numeric::smallint, (m ->> 'collector_at')::timestamptz,
         m ->> 'meter_serial', m ->> 'profile', (m ->> 'profile_version')::numeric::bigint,
         (m ->> 'meter_time')::timestamp
  FROM jsonb_array_elements(coalesce(b -> 'meter_clock_reads', '[]')) m
$$;

-- As in 0021_collector_config.sql, storing the stored entries and meter-clock
-- reads. An entry copied again (a later night, another slot or address) is a
-- duplicate when it says the same: value, interval, profile version and
-- product code; where, when and for what it was copied is evidence of the
-- copy, not part of the entry. One that says otherwise is kept as a conflict,
-- as is a meter-clock read that says otherwise under a taken key.
-- contract: central/test/ingest.sql, central/test/stored.sql, central/test/requests.sql, central/test/collector_config.sql
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
      'conflicting', meter_clocks_conflicting))
    || jsonb_strip_nulls(jsonb_build_object(
         'jobs', jobs.pending(caller),
         'unknown_requests', to_jsonb(unknown_requests)));
END
$$;

-- What monitor may read of them: every row, with when its batch first
-- arrived, so a late copy is found by arrival. The future minkanakku role
-- reads all four too, a widening of its interface; it is not built here.
-- contract: central/test/grants.sql
CREATE VIEW health.stored_entries AS
  SELECT s.*, b.received_at
  FROM store.stored_entries s JOIN store.batches b USING (batch_id);

CREATE VIEW health.stored_entry_conflicts AS
  SELECT * FROM store.stored_entry_conflicts;

CREATE VIEW health.meter_clock_reads AS
  SELECT m.*, b.received_at
  FROM store.meter_clock_reads m JOIN store.batches b USING (batch_id);

CREATE VIEW health.meter_clock_read_conflicts AS
  SELECT * FROM store.meter_clock_read_conflicts;

GRANT SELECT ON health.stored_entries, health.stored_entry_conflicts, health.meter_clock_reads,
  health.meter_clock_read_conflicts TO monitor;

-- migrate:down
-- Forward only: a rollback would drop raw data. Undo with a new migration.
