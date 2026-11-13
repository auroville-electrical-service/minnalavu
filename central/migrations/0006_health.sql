-- migrate:up

-- Health views, read by the operator and the alert job (central/bin/alert) as
-- members of the role monitor, which may read these views and nothing else.
-- contract: central/test/grants.sql

DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'monitor') THEN
    -- A group role: logins are members of it (central/README.md).
    CREATE ROLE monitor NOLOGIN;
  END IF;
END
$$;

CREATE SCHEMA health;
COMMENT ON SCHEMA health IS
  'Views of collection health. The role monitor may read them and nothing else.';
GRANT USAGE ON SCHEMA health TO monitor;

-- What the health views judge by; the row set last holds.
-- contract: central/test/health.sql
CREATE TABLE registry.health_thresholds (
  version_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  set_at timestamptz NOT NULL DEFAULT now(),
  -- A collector in service with no upload for longer is silent.
  collector_silent_after interval NOT NULL CHECK (collector_silent_after > interval '0'),
  -- A meter in service with no reading for this many of its intervals is silent.
  meter_silent_intervals numeric NOT NULL CHECK (meter_silent_intervals >= 1),
  -- A backlog at or above this share of the buffer's capacity is near capacity.
  backlog_near_capacity numeric NOT NULL
    CHECK (backlog_near_capacity > 0 AND backlog_near_capacity <= 1),
  -- How far back missed reads are counted and unregistered serials looked for.
  lookback interval NOT NULL CHECK (lookback > interval '0')
);
CREATE TRIGGER refuse_change BEFORE UPDATE OR DELETE ON registry.health_thresholds
  FOR EACH ROW EXECUTE FUNCTION registry.refuse_change();
CREATE TRIGGER refuse_truncate BEFORE TRUNCATE ON registry.health_thresholds
  FOR EACH STATEMENT EXECUTE FUNCTION registry.refuse_change();

-- Initial values; change them with admin.set_health_thresholds.
INSERT INTO registry.health_thresholds
  (collector_silent_after, meter_silent_intervals, backlog_near_capacity, lookback)
VALUES (interval '1 hour', 4, 0.8, interval '1 day');

CREATE FUNCTION admin.set_health_thresholds(
  collector_silent_after interval, meter_silent_intervals numeric,
  backlog_near_capacity numeric, lookback interval
) RETURNS bigint
LANGUAGE sql AS $$
  INSERT INTO registry.health_thresholds
    (collector_silent_after, meter_silent_intervals, backlog_near_capacity, lookback)
  VALUES (collector_silent_after, meter_silent_intervals, backlog_near_capacity, lookback)
  RETURNING version_id
$$;

-- For the last reading per meter and per collector, in the health views.
CREATE INDEX ON store.readings (meter_serial, read_at DESC);
CREATE INDEX ON store.readings (collector_id, read_at DESC);

-- The views call none of our functions: a function in a view is checked
-- against the reader's privileges, and monitor may execute none.

CREATE VIEW health.thresholds AS
  SELECT collector_silent_after, meter_silent_intervals, backlog_near_capacity, lookback, set_at
  FROM registry.health_thresholds
  ORDER BY version_id DESC
  LIMIT 1;

-- contract: central/test/health.sql
CREATE VIEW health.collectors AS
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
         c.endpoints > 0 AND u.backlog_quarantined > 0 AS has_quarantined
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
COMMENT ON COLUMN health.collectors.clock_source IS
  'As of the batch first received last; a draining backlog sends its oldest batches first.';

-- contract: central/test/health.sql
CREATE VIEW health.meters AS
  WITH t AS (SELECT * FROM health.thresholds),
  m AS (
    SELECT m.serial, m.in_service, m.endpoint_id, m.unit_id, m.profile, e.collector_id,
           e.polled_by_other_system,
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
          WHERE r.meter_serial = m.serial AND r.read_at > now() - t.lookback
          GROUP BY r.reason) g
  ) x ON true;

-- The serial is shown cut to 100 characters, control characters as ?.
-- contract: central/test/health.sql
CREATE VIEW health.unregistered_serials AS
  SELECT regexp_replace(left(r.meter_serial, 100), '[[:cntrl:]]', '?', 'g') AS serial,
         count(*) AS readings, max(r.read_at) AS last_reading_at,
         array_agg(DISTINCT r.collector_id ORDER BY r.collector_id) AS collectors
  FROM store.readings r
  CROSS JOIN health.thresholds t
  WHERE r.read_at > now() - t.lookback
    AND NOT EXISTS (SELECT FROM registry.meters m WHERE m.serial = r.meter_serial)
  GROUP BY r.meter_serial;

-- One row per problem: (kind, subject) names it, detail describes it now.
-- contract: central/test/health.sql
CREATE VIEW health.problems AS
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
  FROM health.unregistered_serials u;

GRANT SELECT ON health.thresholds, health.collectors, health.meters, health.unregistered_serials,
  health.problems TO monitor;

-- migrate:down
-- Forward only. Undo with a new migration.
