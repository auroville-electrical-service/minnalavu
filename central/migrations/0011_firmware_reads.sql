-- migrate:up

-- The software and firmware names a meter reported, as read. The collector
-- sends a record when the names differ from the last it sent for an address,
-- and the first after it starts, so consecutive records may be identical.
-- Keyed on where and when they were read, as missed reads are: a host and
-- port are unique only per collector (registry.check_history). A name is NULL
-- when the meter did not give it.
-- contract: central/test/ingest.sql
CREATE TABLE store.firmware_reads (
  meter_serial text NOT NULL,
  product_code text NOT NULL,
  read_at timestamptz NOT NULL,
  software text,
  firmware_1 text,
  firmware_2 text,
  modbus_version text,
  endpoint_host text NOT NULL,
  endpoint_port integer NOT NULL,
  unit_id smallint NOT NULL,
  collector_id text NOT NULL REFERENCES store.collectors (id),
  batch_id uuid NOT NULL REFERENCES store.batches (batch_id),
  CONSTRAINT firmware_reads_key
    UNIQUE (collector_id, endpoint_host, endpoint_port, unit_id, read_at)
);
COMMENT ON COLUMN store.firmware_reads.meter_serial IS
  'The serial the meter reported in the round the names were read in.';
COMMENT ON COLUMN store.firmware_reads.read_at IS
  'The collector''s clock when the names were read; see the batch''s clock_source.';
-- For the latest names per serial, in health.meter_firmware.
CREATE INDEX ON store.firmware_reads (meter_serial, read_at DESC);

CREATE TRIGGER refuse_change BEFORE UPDATE OR DELETE ON store.firmware_reads
  FOR EACH ROW EXECUTE FUNCTION store.refuse_change();
CREATE TRIGGER refuse_truncate BEFORE TRUNCATE ON store.firmware_reads
  FOR EACH STATEMENT EXECUTE FUNCTION store.refuse_change();

-- A name as decoded: printable ASCII with nothing to trim, at most the 125
-- registers a read returns, two characters each.
CREATE FUNCTION store.check_name(v jsonb, path text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF v <> 'null'::jsonb THEN
    PERFORM store.check_string(v, path, 250);
    PERFORM store.check_match(v, path, '^[!-~]([ -~]*[!-~])?$',
      'printable ASCII with no leading or trailing space');
  END IF;
END
$$;

CREATE FUNCTION store.check_firmware_read(v jsonb, path text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM store.check_object(v, path, ARRAY[
    'endpoint', 'unit_id', 'meter_serial', 'product_code', 'timestamp', 'software',
    'firmware_1', 'firmware_2', 'modbus_version']);
  PERFORM store.check_object(v -> 'endpoint', path || '.endpoint', ARRAY['host', 'port']);
  PERFORM store.check_string(v -> 'endpoint' -> 'host', path || '.endpoint.host', 2147483647);
  PERFORM store.check_integer(v -> 'endpoint' -> 'port', path || '.endpoint.port', 1, 65535);
  PERFORM store.check_integer(v -> 'unit_id', path || '.unit_id', 1, 247);
  PERFORM store.check_string(v -> 'meter_serial', path || '.meter_serial', 2147483647);
  PERFORM store.check_string(v -> 'product_code', path || '.product_code', 2147483647);
  PERFORM store.check_datetime(v -> 'timestamp', path || '.timestamp');
  PERFORM store.check_name(v -> n, path || '.' || n)
    FROM unnest(ARRAY['software', 'firmware_1', 'firmware_2', 'modbus_version']) n;
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
    ARRAY['firmware_reads']);
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
END
$$;

-- A checked batch's firmware reads as rows; none when it carries none.
CREATE FUNCTION store.batch_firmware_reads(b jsonb)
RETURNS TABLE (
  meter_serial text, product_code text, read_at timestamptz, software text, firmware_1 text,
  firmware_2 text, modbus_version text, endpoint_host text, endpoint_port integer,
  unit_id smallint
)
LANGUAGE sql STABLE AS $$
  SELECT f ->> 'meter_serial', f ->> 'product_code', (f ->> 'timestamp')::timestamptz,
         f ->> 'software', f ->> 'firmware_1', f ->> 'firmware_2', f ->> 'modbus_version',
         f -> 'endpoint' ->> 'host', (f -> 'endpoint' ->> 'port')::numeric::integer,
         (f ->> 'unit_id')::numeric::smallint
  FROM jsonb_array_elements(coalesce(b -> 'firmware_reads', '[]')) f
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
  firmware_in integer;
  firmware_new integer;
  firmware_conflicting integer;
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
      'duplicate', missed_in - missed_new),
    'firmware_reads', jsonb_build_object(
      'received', firmware_in,
      'inserted', firmware_new,
      'duplicate', firmware_in - firmware_new - firmware_conflicting,
      'conflicting', firmware_conflicting));
END
$$;

-- Per meter serial, the latest names it reported; the latest record before
-- them whose names differ (previous), since the collector resends unchanged
-- names on every start; and the first record of the run that holds the latest
-- names (first_read_at, first_received_at), which a resend does not move. The
-- latest is by read_at, then address, so a tie is settled the same way every
-- time. The serial, product codes and host are shown cut to 100 characters,
-- control characters as ?.
-- contract: central/test/health.sql
CREATE VIEW health.meter_firmware AS
  WITH ranked AS (
    SELECT f.*, b.received_at,
           row_number() OVER (PARTITION BY f.meter_serial
                              ORDER BY f.read_at DESC, f.collector_id, f.endpoint_host,
                                       f.endpoint_port, f.unit_id) AS n,
           count(*) OVER (PARTITION BY f.meter_serial) AS records
    FROM store.firmware_reads f
    JOIN store.batches b USING (batch_id)
  ),
  latest AS (
    SELECT l.*,
           (SELECT min(r.n) FROM ranked r
            WHERE r.meter_serial = l.meter_serial
              AND (r.software, r.firmware_1, r.firmware_2, r.modbus_version)
                  IS DISTINCT FROM (l.software, l.firmware_1, l.firmware_2, l.modbus_version))
             AS previous_n
    FROM ranked l
    WHERE l.n = 1
  )
  SELECT regexp_replace(left(l.meter_serial, 100), '[[:cntrl:]]', '?', 'g') AS serial,
         regexp_replace(left(l.product_code, 100), '[[:cntrl:]]', '?', 'g') AS product_code,
         l.software, l.firmware_1, l.firmware_2, l.modbus_version, l.read_at, l.received_at,
         l.collector_id,
         regexp_replace(left(l.endpoint_host, 100), '[[:cntrl:]]', '?', 'g') AS endpoint_host,
         l.endpoint_port, l.unit_id,
         s.read_at AS first_read_at, s.received_at AS first_received_at,
         p.software AS previous_software, p.firmware_1 AS previous_firmware_1,
         p.firmware_2 AS previous_firmware_2, p.modbus_version AS previous_modbus_version,
         p.read_at AS previous_read_at,
         p.n IS NOT NULL AS changed
  FROM latest l
  LEFT JOIN ranked p ON p.meter_serial = l.meter_serial AND p.n = l.previous_n
  JOIN ranked s ON s.meter_serial = l.meter_serial
               AND s.n = coalesce(l.previous_n, l.records + 1) - 1;

-- One row per problem: (kind, subject) names it, detail describes it now.
-- A firmware change is judged by when the first record of its new names
-- arrived, so a change read weeks ago at an offline site is flagged when it
-- reaches the store, and a resend of the same names neither hides nor renews it.
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

GRANT SELECT ON health.meter_firmware TO monitor;

-- migrate:down
-- Forward only: a rollback would drop raw data. Undo with a new migration.
