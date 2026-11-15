-- migrate:up

-- The polling config served from the registry: the calling collector's
-- endpoints and targets in service now, as contract/config's schema version
-- 1, whether or not it validates (the collector refuses one that does not);
-- its digest in every ingest answer; and the collector's report of the
-- config it applies and the one it refused, kept per upload with the rest
-- of its backlog.

-- RFC 8785 (JCS) for a polling config: no whitespace, keys sorted by their
-- bytes, jsonb's own text for strings (escaped as JCS does), integers,
-- booleans and null.
-- contract: central/test/collector_config.sql
CREATE FUNCTION registry.canonical_json(v jsonb) RETURNS text
LANGUAGE plpgsql IMMUTABLE STRICT AS $$
BEGIN
  RETURN CASE jsonb_typeof(v)
    WHEN 'object' THEN
      '{' || coalesce((SELECT string_agg(to_jsonb(k)::text || ':' || registry.canonical_json(x), ','
                                         ORDER BY k COLLATE "C")
                       FROM jsonb_each(v) e(k, x)), '') || '}'
    WHEN 'array' THEN
      '[' || coalesce((SELECT string_agg(registry.canonical_json(x), ',' ORDER BY i)
                       FROM jsonb_array_elements(v) WITH ORDINALITY a(x, i)), '') || ']'
    ELSE v::text
  END;
END
$$;

-- contract/fixtures/config.v1.digests.json: SHA-256 of the canonical
-- encoding's UTF-8 bytes, in lowercase hex.
-- contract: central/test/collector_config.sql
CREATE FUNCTION registry.config_digest(document jsonb) RETURNS text
LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT encode(sha256(convert_to(registry.canonical_json(document), 'UTF8')), 'hex')
$$;

-- A collector's polling config as of now(): its endpoints in service, by
-- host and port, each with its targets in service, by unit id, and the
-- serial of the meter placed at each when there is one. A target with no
-- interval of its own leaves it out, so its endpoint's applies. An endpoint
-- with no target in service has no meters, and a collector with no endpoint
-- in service none: served as they are, for the collector to refuse.
-- contract: central/test/collector_config.sql
CREATE FUNCTION registry.collector_config(collector text) RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'schema_version', 1,
    'endpoints', coalesce(jsonb_agg(x.endpoint ORDER BY x.host COLLATE "C", x.port), '[]'))
  FROM (
    SELECT e.host, e.port, jsonb_strip_nulls(jsonb_build_object(
             'host', e.host, 'port', e.port, 'framing', e.framing,
             'max_timeouts', e.max_timeouts,
             'polled_by_other_system', e.polled_by_other_system,
             'timeout_ms', e.timeout_ms, 'retries', e.retries,
             'busy_backoff_ms', e.busy_backoff_ms,
             'reconnect_backoff_ms', jsonb_build_object('min', e.reconnect_backoff_min_ms,
                                                        'max', e.reconnect_backoff_max_ms),
             'interval_ms', e.interval_ms,
             'meters', coalesce(
               (SELECT jsonb_agg(jsonb_build_object('unit_id', g.unit_id, 'serial', m.serial,
                                                    'profile', g.profile,
                                                    'interval_ms', g.interval_ms)
                                 ORDER BY g.unit_id)
                FROM registry.target_history g
                LEFT JOIN registry.meter_history m
                  ON (m.endpoint_id, m.unit_id) = (g.endpoint_id, g.unit_id)
                 AND m.in_service AND m.period @> now()
                WHERE g.endpoint_id = e.endpoint_id AND g.in_service AND g.period @> now()),
               '[]'))) AS endpoint
    FROM registry.endpoint_history e
    WHERE e.collector_id = collector AND e.in_service AND e.period @> now()
  ) x
$$;

-- GET /rpc/collector_config: the calling collector's polling config, or 403
-- for a role that is not a registered collector.
-- contract: central/test/collector_config.sql, central/test/grants.sql
CREATE FUNCTION api.collector_config() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  caller text := store.caller();
BEGIN
  IF caller IS NULL THEN
    RAISE SQLSTATE 'PT403' USING MESSAGE = 'the caller is not a registered collector';
  END IF;
  RETURN registry.collector_config(caller);
END
$$;

GRANT EXECUTE ON FUNCTION api.collector_config() TO collector;

-- The backlog's config, as the collector reported it; NULL from a collector
-- that does not report one.
-- contract: central/test/ingest.sql, central/test/collector_config.sql
ALTER TABLE store.uploads
  ADD COLUMN config_digest text CHECK (config_digest ~ '^[0-9a-f]{64}$'),
  ADD COLUMN config_refused_digest text CHECK (config_refused_digest ~ '^[0-9a-f]{64}$'),
  ADD COLUMN config_refusal_reason text CHECK (length(config_refusal_reason) BETWEEN 1 AND 1000),
  ADD CONSTRAINT config_refused_with_reason
    CHECK ((config_refused_digest IS NULL) = (config_refusal_reason IS NULL)),
  ADD CONSTRAINT config_refused_beside_applied
    CHECK (config_refused_digest IS NULL OR config_digest IS NOT NULL);
COMMENT ON COLUMN store.uploads.config_digest IS
  'The digest of the polling config the collector was applying (contract/fixtures/config.v1.digests.json).';
COMMENT ON COLUMN store.uploads.config_refused_digest IS
  'The digest of a served config the collector refused, with config_refusal_reason; NULL when it reported none.';

-- contract: central/test/schema.sql
CREATE FUNCTION store.check_config_report(v jsonb, path text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM store.check_object(v, path, ARRAY['digest', 'refused_digest', 'reason']);
  PERFORM store.check_match(v -> 'digest', path || '.digest', '^[0-9a-f]{64}$',
                            'a SHA-256 digest in lowercase hex');
  IF v -> 'refused_digest' = 'null'::jsonb THEN
    IF v -> 'reason' <> 'null'::jsonb THEN
      PERFORM store.reject(path || '.reason', 'must be null when refused_digest is');
    END IF;
    RETURN;
  END IF;
  PERFORM store.check_match(v -> 'refused_digest', path || '.refused_digest', '^[0-9a-f]{64}$',
                            'null or a SHA-256 digest in lowercase hex');
  PERFORM store.check_string(v -> 'reason', path || '.reason', 1000);
END
$$;

-- As in 0018_latency.sql, the backlog with an optional config.
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
END
$$;

-- As in 0018_latency.sql, keeping the backlog's config with the upload, and
-- answering with the digest of the config the collector is served now.
-- contract: central/test/ingest.sql, central/test/requests.sql, central/test/collector_config.sql
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
     readings_conflicting, missed_reads_inserted, missed_reads_duplicate, config_digest,
     config_refused_digest, config_refusal_reason)
  SELECT id, caller, now(), (b ->> 'sent_at')::timestamptz,
         (k ->> 'events')::numeric, (k ->> 'bytes')::numeric, (k ->> 'batches')::numeric,
         (k ->> 'oldest')::timestamptz, (k ->> 'max_bytes')::numeric,
         (k ->> 'refused')::numeric, (k ->> 'discarded_files')::numeric,
         (k ->> 'quarantined')::numeric,
         readings_new, readings_in - readings_new - readings_conflicting, readings_conflicting,
         missed_new, missed_in - missed_new,
         k -> 'config' ->> 'digest', k -> 'config' ->> 'refused_digest',
         k -> 'config' ->> 'reason'
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
      'conflicting', latency_conflicting))
    || jsonb_strip_nulls(jsonb_build_object(
         'jobs', jobs.pending(caller),
         'unknown_requests', to_jsonb(unknown_requests)));
END
$$;

-- contract: central/test/health.sql
CREATE OR REPLACE VIEW health.collectors AS
  WITH t AS (SELECT * FROM health.thresholds),
  c AS (
    SELECT c.id AS collector_id, c.created_at,
           (SELECT count(*) FROM registry.endpoint_history e
            WHERE e.collector_id = c.id AND e.in_service AND e.period @> now()) AS endpoints
    FROM store.collectors c
  )
  SELECT c.collector_id, c.endpoints > 0 AS in_service, c.endpoints,
         u.received_at AS last_upload_at,
         (SELECT max(r.read_at) FROM store.readings r WHERE r.collector_id = c.collector_id)
           AS last_reading_at,
         b.clock_source, b.clock_last_sync_at,
         u.backlog_events, u.backlog_bytes, u.backlog_batches, u.backlog_oldest,
         u.backlog_max_bytes,
         round(u.backlog_bytes::numeric / u.backlog_max_bytes, 4) AS backlog_used,
         u.backlog_refused, u.backlog_discarded_files, u.backlog_quarantined,
         coalesce(m.missed, 0) AS missed_reads, coalesce(m.by_reason, '{}') AS missed_by_reason,
         c.endpoints > 0
           AND coalesce(u.received_at, c.created_at) < now() - t.collector_silent_after AS silent,
         c.endpoints > 0
           AND u.backlog_bytes >= t.backlog_near_capacity * u.backlog_max_bytes
           AS backlog_near_capacity,
         c.endpoints > 0 AND u.backlog_refused > 0 AS has_refused,
         c.endpoints > 0 AND u.backlog_discarded_files > 0 AS has_discarded,
         c.endpoints > 0 AND u.backlog_quarantined > 0 AS has_quarantined,
         u.config_digest, u.config_refused_digest, u.config_refusal_reason,
         c.endpoints > 0 AND u.config_refused_digest IS NOT NULL AS has_config_refused
  FROM c
  CROSS JOIN t
  LEFT JOIN LATERAL (
    SELECT * FROM store.uploads u WHERE u.collector_id = c.collector_id
    ORDER BY u.received_at DESC, u.upload_id DESC LIMIT 1
  ) u ON true
  LEFT JOIN LATERAL (
    SELECT * FROM store.batches b WHERE b.collector_id = c.collector_id
    ORDER BY b.received_at DESC LIMIT 1
  ) b ON true
  LEFT JOIN LATERAL (
    SELECT sum(n) AS missed, jsonb_object_agg(reason::text, n) AS by_reason
    FROM (SELECT x.reason, count(*) AS n FROM store.missed_reads x
          WHERE x.collector_id = c.collector_id AND x.read_at > now() - t.lookback
          GROUP BY x.reason) g
  ) m ON true;

-- contract: central/test/health.sql, central/test/collector_config.sql
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
  SELECT 'config_refused', c.collector_id,
         format('refused the served config %s (%s); still applying %s', c.config_refused_digest,
                regexp_replace(c.config_refusal_reason, '[[:cntrl:]]', '?', 'g'), c.config_digest)
  FROM health.collectors c WHERE c.has_config_refused
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
  SELECT 'target_silent', format('%s unit %s', g.endpoint_id, g.unit_id),
         format('no reading or missed read since %s (expected every %s), at %s:%s unit %s '
                || 'via %s, profile %s, %s',
                coalesce(greatest(g.last_reading_at, g.last_missed_read_at)::text,
                         'it came into service'),
                g.expected_interval, g.host, g.port, g.unit_id, g.collector_id, g.profile,
                coalesce('meter ' || g.serial, 'no meter placed'))
  FROM health.targets g
  JOIN health.collectors c USING (collector_id)
  WHERE g.silent AND NOT c.silent
  UNION ALL
  SELECT 'meter_silent', m.serial,
         format('no reading since %s (expected every %s), on %s unit %s, collector %s',
                coalesce(m.last_reading_at::text, 'it came into service'), m.expected_interval,
                m.endpoint_id, m.unit_id, m.collector_id)
  FROM health.meters m
  JOIN health.collectors c USING (collector_id)
  JOIN health.targets g USING (endpoint_id, unit_id)
  WHERE m.silent AND NOT c.silent AND NOT g.silent
  UNION ALL
  SELECT 'endpoint_errors', e.endpoint_id,
         format('%s of %s reads failed (%s%%) within %s, missed by reason %s, at %s:%s via %s',
                e.failed_reads, e.readings + e.missed_reads, round(e.error_rate * 100, 2),
                t.lookback, e.missed_by_reason, e.host, e.port, e.collector_id)
  FROM health.endpoints e
  CROSS JOIN health.thresholds t
  WHERE e.erroring
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
  WHERE f.changed AND f.first_received_at > now() - t.lookback
  UNION ALL
  SELECT 'energy_backwards', e.serial,
         string_agg(format('%s %s %s at %s (%s) after %s %s at %s (%s)%s',
                           e.register_key, e.value, e.unit, e.read_at,
                           e.collector_id || ', clock ' || e.clock_source
                           || CASE WHEN e.grounded THEN ', checked' ELSE ', unchecked' END,
                           e.previous_value, e.previous_unit, e.previous_read_at,
                           e.previous_collector_id || ', clock ' || e.previous_clock_source
                           || CASE WHEN e.previous_grounded THEN ', checked' ELSE ', unchecked' END,
                           CASE WHEN e.suspect THEN ', suspect: no clock check grounds either'
                                ELSE '' END),
                    '; ' ORDER BY e.register_key, e.read_at)
  FROM health.energy_drops e
  GROUP BY e.serial;

-- migrate:down
-- Forward only. Undo with a new migration.
