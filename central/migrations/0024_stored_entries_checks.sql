-- migrate:up

-- Checks of batch.v1's stored entries and meter-clock reads. A batch carrying
-- either is checked as the schema checks it; api.ingest stores neither.

-- batch.v1's meter_time: a local date-time to the second, no zone or offset,
-- on a day that exists. The schema's pattern cannot see the day; no decoded
-- stamp lands on one that does not exist.
CREATE FUNCTION store.check_meter_time(v jsonb, path text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM store.check_match(v, path,
    '^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]$',
    'a local date-time with no zone, such as 2026-11-01T00:00:00');
  PERFORM (v #>> '{}')::timestamp;
EXCEPTION
  WHEN datetime_field_overflow OR invalid_datetime_format THEN
    PERFORM store.reject(path, 'is not a date that exists');
END
$$;

-- The endpoint, unit, serial and profile version a stored entry and a
-- meter-clock read share.
CREATE FUNCTION store.check_copied_meter(v jsonb, path text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM store.check_object(v -> 'endpoint', path || '.endpoint', ARRAY['host', 'port']);
  PERFORM store.check_string(v -> 'endpoint' -> 'host', path || '.endpoint.host', 2147483647);
  PERFORM store.check_integer(v -> 'endpoint' -> 'port', path || '.endpoint.port', 1, 65535);
  PERFORM store.check_integer(v -> 'unit_id', path || '.unit_id', 1, 247);
  PERFORM store.check_string(v -> 'meter_serial', path || '.meter_serial', 2147483647);
  PERFORM store.check_string(v -> 'profile', path || '.profile', 2147483647);
  PERFORM store.check_count(v -> 'profile_version', path || '.profile_version', 1);
  PERFORM store.check_meter_time(v -> 'meter_time', path || '.meter_time');
END
$$;

-- A load-survey entry carries its interval; no other entry has one.
-- contract: central/test/schema.sql
CREATE FUNCTION store.check_stored_entry(v jsonb, path text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  fields text[] := ARRAY[
    'endpoint', 'unit_id', 'meter_serial', 'product_code', 'profile', 'profile_version', 'store',
    'meter_time', 'register_key', 'value', 'slot', 'copied_at'];
BEGIN
  PERFORM store.check_object(v, path, fields, ARRAY['interval_s', 'request_id']);
  PERFORM store.check_enum(v -> 'store', path || '.store',
    enum_range(NULL::store.stored_store)::text[]);
  IF v ->> 'store' = 'load_survey' THEN
    PERFORM store.check_object(v, path, fields || ARRAY['interval_s'], ARRAY['request_id']);
    PERFORM store.check_integer(v -> 'interval_s', path || '.interval_s', 1, 86400);
  ELSE
    PERFORM store.check_object(v, path, fields, ARRAY['request_id']);
  END IF;
  PERFORM store.check_copied_meter(v, path);
  PERFORM store.check_string(v -> 'product_code', path || '.product_code', 2147483647);
  PERFORM store.check_string(v -> 'register_key', path || '.register_key', 2147483647);
  PERFORM store.check_match(v -> 'value', path || '.value', '^-?[0-9]+(\.[0-9]+)?$',
    'a decimal string such as "1234.56"');
  PERFORM store.check_integer(v -> 'slot', path || '.slot', 0, 65535);
  PERFORM store.check_time(v -> 'copied_at', path || '.copied_at', 6, 'microseconds');
  IF v ? 'request_id' THEN
    PERFORM store.check_uuid(v -> 'request_id', path || '.request_id');
  END IF;
END
$$;

-- contract: central/test/schema.sql
CREATE FUNCTION store.check_meter_clock_read(v jsonb, path text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM store.check_object(v, path, ARRAY[
    'endpoint', 'unit_id', 'meter_serial', 'profile', 'profile_version', 'meter_time',
    'collector_at']);
  PERFORM store.check_copied_meter(v, path);
  PERFORM store.check_time(v -> 'collector_at', path || '.collector_at', 6, 'microseconds');
END
$$;

-- As in 0021_collector_config.sql, with the optional stored entries and
-- meter-clock reads.
-- contract: central/test/schema.sql
CREATE OR REPLACE FUNCTION store.check_batch(b jsonb) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  e record;
BEGIN
  PERFORM store.check_object(b, 'batch', ARRAY[
    'schema_version', 'batch_id', 'sent_at', 'clock', 'backlog', 'readings', 'missed_reads'],
    ARRAY['firmware_reads', 'clock_checks', 'latency', 'stored_entries', 'meter_clock_reads']);
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
    'quarantined'], ARRAY['config']);
  IF b -> 'backlog' ? 'config' THEN
    PERFORM store.check_config_report(b -> 'backlog' -> 'config', 'batch.backlog.config');
  END IF;
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

  IF b ? 'stored_entries' THEN
    PERFORM store.check_array(b -> 'stored_entries', 'batch.stored_entries', 0, 2147483647);
    FOR e IN SELECT value, ordinality - 1 AS i FROM jsonb_array_elements(b -> 'stored_entries') WITH ORDINALITY LOOP
      PERFORM store.check_stored_entry(e.value, format('batch.stored_entries[%s]', e.i));
    END LOOP;
  END IF;

  IF b ? 'meter_clock_reads' THEN
    PERFORM store.check_array(b -> 'meter_clock_reads', 'batch.meter_clock_reads', 0, 2147483647);
    FOR e IN SELECT value, ordinality - 1 AS i FROM jsonb_array_elements(b -> 'meter_clock_reads') WITH ORDINALITY LOOP
      PERFORM store.check_meter_clock_read(e.value, format('batch.meter_clock_reads[%s]', e.i));
    END LOOP;
  END IF;
END
$$;

-- migrate:down
-- Forward only: undo with a new migration.
