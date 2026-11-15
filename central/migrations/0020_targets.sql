-- migrate:up

-- Polling targets: a place to poll, an endpoint's unit id, held apart from
-- the meter placed there, so that a unit is polled whether or not its serial
-- is known. A target holds the profile and interval it is polled with; a
-- meter's history places its serial at a target and holds nothing else. The
-- meter history is rebuilt in that shape: each place a meter was ever named
-- at becomes a target, in service exactly while a meter was, with that
-- meter's profile and interval.
-- contract: central/test/registry.sql

CREATE TABLE registry.targets (
  endpoint_id text NOT NULL REFERENCES registry.endpoints (id),
  unit_id smallint NOT NULL CHECK (unit_id BETWEEN 1 AND 247),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (endpoint_id, unit_id)
);
COMMENT ON TABLE registry.targets IS
  'One row per place to poll: a unit id on an endpoint''s chain, whatever meter answers there.';

CREATE TABLE registry.target_versions (
  version_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  endpoint_id text NOT NULL,
  unit_id smallint NOT NULL,
  valid_from timestamptz NOT NULL CHECK (isfinite(valid_from)),
  recorded_at timestamptz NOT NULL DEFAULT now(),
  in_service boolean NOT NULL,
  -- A profile in contract/profiles/, by name.
  profile text NOT NULL CHECK (profile ~ '^[a-z][a-z0-9_]{0,39}$'),
  interval_ms integer CHECK (interval_ms BETWEEN 1 AND 86400000),
  FOREIGN KEY (endpoint_id, unit_id) REFERENCES registry.targets (endpoint_id, unit_id)
);
COMMENT ON COLUMN registry.target_versions.interval_ms IS
  'How often the unit is read; NULL means its endpoint''s interval, as in the polling config.';
COMMENT ON COLUMN registry.target_versions.in_service IS
  'false from the target''s retirement on; the other columns then say how it was last polled.';
CREATE INDEX ON registry.target_versions (endpoint_id, unit_id, valid_from);

-- The meter history as it held, to rebuild from.
CREATE TEMP TABLE old_meter_versions ON COMMIT DROP AS
  SELECT * FROM registry.meter_versions;
CREATE TEMP TABLE old_meter_history ON COMMIT DROP AS
  SELECT serial, endpoint_id, unit_id, in_service, profile, interval_ms,
         tstzrange(valid_from, lead(valid_from) OVER w) AS period
  FROM (
    SELECT DISTINCT ON (serial, valid_from) * FROM old_meter_versions
    ORDER BY serial, valid_from, version_id DESC
  ) v
  WINDOW w AS (PARTITION BY serial ORDER BY valid_from);

DROP VIEW health.problems;
DROP VIEW health.meters;
DROP VIEW health.misplaced_serials;
DROP VIEW registry.meter_history;
DROP FUNCTION admin.swap_meter(text, text, timestamptz, text);
DROP FUNCTION admin.register_meter(text, timestamptz, text, integer, text, integer);
DROP FUNCTION admin.change_meter(text, timestamptz, text, integer, text, integer);
DROP TABLE registry.meter_versions;

CREATE TABLE registry.meter_versions (
  version_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  serial text NOT NULL REFERENCES registry.meters (serial),
  valid_from timestamptz NOT NULL CHECK (isfinite(valid_from)),
  recorded_at timestamptz NOT NULL DEFAULT now(),
  in_service boolean NOT NULL,
  endpoint_id text NOT NULL,
  unit_id smallint NOT NULL,
  FOREIGN KEY (endpoint_id, unit_id) REFERENCES registry.targets (endpoint_id, unit_id)
);
COMMENT ON COLUMN registry.meter_versions.in_service IS
  'false from the meter''s retirement on; the target then says where it was last.';
CREATE INDEX ON registry.meter_versions (serial, valid_from);
CREATE INDEX ON registry.meter_versions (endpoint_id, unit_id);

DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['targets', 'target_versions', 'meter_versions'] LOOP
    EXECUTE format(
      'CREATE TRIGGER refuse_change BEFORE UPDATE OR DELETE ON registry.%I
         FOR EACH ROW EXECUTE FUNCTION registry.refuse_change()', t);
    EXECUTE format(
      'CREATE TRIGGER refuse_truncate BEFORE TRUNCATE ON registry.%I
         FOR EACH STATEMENT EXECUTE FUNCTION registry.refuse_change()', t);
  END LOOP;
END
$$;

INSERT INTO registry.targets (endpoint_id, unit_id)
SELECT DISTINCT endpoint_id, unit_id FROM old_meter_versions;

-- A target's state at each time a meter came to it or left it: in service
-- with the meter's profile and interval while one was there, else retired
-- with the last one's.
INSERT INTO registry.target_versions
  (endpoint_id, unit_id, valid_from, in_service, profile, interval_ms)
WITH placed AS (
  SELECT * FROM old_meter_history WHERE in_service
), points AS (
  SELECT endpoint_id, unit_id, lower(period) AS t FROM placed
  UNION
  SELECT endpoint_id, unit_id, upper(period) FROM placed WHERE upper(period) IS NOT NULL
)
SELECT p.endpoint_id, p.unit_id, p.t, s.in_service, s.profile, s.interval_ms
FROM points p
CROSS JOIN LATERAL (
  SELECT h.period @> p.t AS in_service, h.profile, h.interval_ms
  FROM placed h
  WHERE (h.endpoint_id, h.unit_id) = (p.endpoint_id, p.unit_id) AND lower(h.period) <= p.t
  ORDER BY h.period @> p.t DESC, lower(h.period) DESC
  LIMIT 1
) s
ORDER BY p.endpoint_id, p.unit_id, p.t;

INSERT INTO registry.meter_versions
  (version_id, serial, valid_from, recorded_at, in_service, endpoint_id, unit_id)
OVERRIDING SYSTEM VALUE
SELECT version_id, serial, valid_from, recorded_at, in_service, endpoint_id, unit_id
FROM old_meter_versions
ORDER BY version_id;
SELECT setval(pg_get_serial_sequence('registry.meter_versions', 'version_id'),
              coalesce((SELECT max(version_id) FROM registry.meter_versions), 0) + 1, false);

-- The state over each period [valid_from, valid_to); valid_to is NULL while open.
CREATE VIEW registry.target_history AS
  SELECT v.endpoint_id, v.unit_id, v.valid_from, lead(v.valid_from) OVER w AS valid_to,
         tstzrange(v.valid_from, lead(v.valid_from) OVER w) AS period,
         v.in_service, v.profile, v.interval_ms, v.version_id, v.recorded_at
  FROM (
    SELECT DISTINCT ON (endpoint_id, unit_id, valid_from) *
    FROM registry.target_versions
    ORDER BY endpoint_id, unit_id, valid_from, version_id DESC
  ) v
  WINDOW w AS (PARTITION BY v.endpoint_id, v.unit_id ORDER BY v.valid_from);

CREATE VIEW registry.meter_history AS
  SELECT v.serial, v.valid_from, lead(v.valid_from) OVER w AS valid_to,
         tstzrange(v.valid_from, lead(v.valid_from) OVER w) AS period,
         v.in_service, v.endpoint_id, v.unit_id, v.version_id, v.recorded_at
  FROM (
    SELECT DISTINCT ON (serial, valid_from) *
    FROM registry.meter_versions
    ORDER BY serial, valid_from, version_id DESC
  ) v
  WINDOW w AS (PARTITION BY v.serial ORDER BY v.valid_from);

-- Checked after every admin change, over the whole history, so a back-dated
-- row is judged against what follows it. Raises exclusion_violation (23P01).
-- contract: central/test/registry.sql
CREATE OR REPLACE FUNCTION registry.check_history() RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  conflict text;
BEGIN
  SELECT format('endpoints %s and %s are both %s:%s on collector %s from %s',
                a.endpoint_id, b.endpoint_id, a.host, a.port, a.collector_id,
                greatest(lower(a.period), lower(b.period)))
    INTO conflict
    FROM registry.endpoint_history a
    JOIN registry.endpoint_history b
      ON a.collector_id = b.collector_id AND a.host = b.host AND a.port = b.port
     AND a.endpoint_id < b.endpoint_id AND a.period && b.period
   WHERE a.in_service AND b.in_service
   LIMIT 1;
  IF conflict IS NULL THEN
    SELECT format('meters %s and %s are both at %s unit %s from %s',
                  a.serial, b.serial, a.endpoint_id, a.unit_id,
                  greatest(lower(a.period), lower(b.period)))
      INTO conflict
      FROM registry.meter_history a
      JOIN registry.meter_history b
        ON a.endpoint_id = b.endpoint_id AND a.unit_id = b.unit_id
       AND a.serial < b.serial AND a.period && b.period
     WHERE a.in_service AND b.in_service
     LIMIT 1;
  END IF;
  IF conflict IS NULL THEN
    SELECT format('%s unit %s is in service from %s, when its endpoint is not',
                  g.endpoint_id, g.unit_id, lower(g.period))
      INTO conflict
      FROM registry.target_history g
     WHERE g.in_service
       AND (lower(g.period) < (SELECT min(e.valid_from) FROM registry.endpoint_versions e
                               WHERE e.endpoint_id = g.endpoint_id)
            OR EXISTS (SELECT FROM registry.endpoint_history e
                       WHERE e.endpoint_id = g.endpoint_id AND NOT e.in_service
                         AND e.period && g.period))
     LIMIT 1;
  END IF;
  IF conflict IS NULL THEN
    SELECT format('meter %s is in service at %s unit %s from %s, when the target is not',
                  m.serial, m.endpoint_id, m.unit_id, lower(m.period))
      INTO conflict
      FROM registry.meter_history m
     WHERE m.in_service
       AND (lower(m.period) < coalesce((SELECT min(g.valid_from) FROM registry.target_versions g
                                        WHERE (g.endpoint_id, g.unit_id)
                                              = (m.endpoint_id, m.unit_id)),
                                       'infinity')
            OR EXISTS (SELECT FROM registry.target_history g
                       WHERE (g.endpoint_id, g.unit_id) = (m.endpoint_id, m.unit_id)
                         AND NOT g.in_service AND g.period && m.period))
     LIMIT 1;
  END IF;
  IF conflict IS NOT NULL THEN
    RAISE EXCEPTION 'registry change refused: %', conflict
      USING ERRCODE = 'exclusion_violation',
            HINT = 'Move or retire what is in the way first, from the same time.';
  END IF;
END
$$;

SELECT registry.check_history();

-- Admin functions, as in 0005_registry.sql: each adds one version row
-- holding from valid_from (which may be in the past), then runs
-- registry.check_history. Call them with named arguments.
-- contract: central/test/registry.sql

CREATE FUNCTION admin.change_target(
  endpoint_id text, unit_id integer, valid_from timestamptz, profile text, interval_ms integer
) RETURNS bigint
LANGUAGE plpgsql AS $$
#variable_conflict use_variable
DECLARE
  v bigint;
BEGIN
  IF NOT EXISTS (SELECT FROM registry.targets g
                 WHERE (g.endpoint_id, g.unit_id) = (endpoint_id, unit_id)) THEN
    RAISE EXCEPTION '% unit % is not registered', endpoint_id, unit_id
      USING HINT = 'Register it with admin.register_target.';
  END IF;
  INSERT INTO registry.target_versions
    (endpoint_id, unit_id, valid_from, in_service, profile, interval_ms)
  VALUES (endpoint_id, unit_id, valid_from, true, profile, interval_ms)
  RETURNING version_id INTO v;
  PERFORM registry.check_history();
  RETURN v;
END
$$;
COMMENT ON FUNCTION admin.change_target IS
  'A target''s whole state from valid_from: its profile, its interval (NULL: its endpoint''s), or a correction of an earlier row.';

CREATE FUNCTION admin.register_target(
  endpoint_id text, unit_id integer, valid_from timestamptz, profile text, interval_ms integer
) RETURNS bigint
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO registry.targets (endpoint_id, unit_id) VALUES (endpoint_id, unit_id);
  RETURN admin.change_target(endpoint_id, unit_id, valid_from, profile, interval_ms);
END
$$;

CREATE FUNCTION admin.retire_target(endpoint_id text, unit_id integer, valid_from timestamptz)
RETURNS bigint
LANGUAGE plpgsql AS $$
#variable_conflict use_variable
DECLARE
  v bigint;
BEGIN
  INSERT INTO registry.target_versions
    (endpoint_id, unit_id, valid_from, in_service, profile, interval_ms)
  SELECT h.endpoint_id, h.unit_id, valid_from, false, h.profile, h.interval_ms
    FROM registry.target_history h
   WHERE (h.endpoint_id, h.unit_id) = (endpoint_id, unit_id) AND h.period @> valid_from
     AND h.in_service
  RETURNING version_id INTO v;
  IF v IS NULL THEN
    RAISE EXCEPTION '% unit % is not in service at %', endpoint_id, unit_id, valid_from;
  END IF;
  PERFORM registry.check_history();
  RETURN v;
END
$$;

CREATE FUNCTION admin.change_meter(
  serial text, valid_from timestamptz, endpoint_id text, unit_id integer
) RETURNS bigint
LANGUAGE plpgsql AS $$
#variable_conflict use_variable
DECLARE
  v bigint;
BEGIN
  IF NOT EXISTS (SELECT FROM registry.meters m WHERE m.serial = serial) THEN
    RAISE EXCEPTION 'meter % is not registered', serial
      USING HINT = 'Register it with admin.register_meter.';
  END IF;
  IF NOT EXISTS (SELECT FROM registry.targets g
                 WHERE (g.endpoint_id, g.unit_id) = (endpoint_id, unit_id)) THEN
    RAISE EXCEPTION '% unit % is not registered', endpoint_id, unit_id
      USING HINT = 'Register it with admin.register_target.';
  END IF;
  INSERT INTO registry.meter_versions (serial, valid_from, in_service, endpoint_id, unit_id)
  VALUES (serial, valid_from, true, endpoint_id, unit_id)
  RETURNING version_id INTO v;
  PERFORM registry.check_history();
  RETURN v;
END
$$;
COMMENT ON FUNCTION admin.change_meter IS
  'A meter''s whole state from valid_from: place it at another target, or correct an earlier row.';

CREATE FUNCTION admin.register_meter(
  serial text, valid_from timestamptz, endpoint_id text, unit_id integer
) RETURNS bigint
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO registry.meters (serial) VALUES (serial);
  RETURN admin.change_meter(serial, valid_from, endpoint_id, unit_id);
END
$$;

CREATE OR REPLACE FUNCTION admin.retire_meter(serial text, valid_from timestamptz) RETURNS bigint
LANGUAGE plpgsql AS $$
#variable_conflict use_variable
DECLARE
  v bigint;
BEGIN
  INSERT INTO registry.meter_versions (serial, valid_from, in_service, endpoint_id, unit_id)
  SELECT h.serial, valid_from, false, h.endpoint_id, h.unit_id
    FROM registry.meter_history h
   WHERE h.serial = serial AND h.period @> valid_from AND h.in_service
  RETURNING version_id INTO v;
  IF v IS NULL THEN
    RAISE EXCEPTION 'meter % is not in service at %', serial, valid_from;
  END IF;
  PERFORM registry.check_history();
  RETURN v;
END
$$;

-- The new meter may already be registered (a spare that was in service
-- elsewhere). It takes the old one's target, which keeps its profile: a new
-- meter of another model needs admin.change_target from the same time.
CREATE FUNCTION admin.swap_meter(old_serial text, new_serial text, swapped_at timestamptz)
RETURNS bigint
LANGUAGE plpgsql AS $$
#variable_conflict use_variable
DECLARE
  was registry.meter_history;
BEGIN
  SELECT * INTO was FROM registry.meter_history h
   WHERE h.serial = old_serial AND h.period @> swapped_at AND h.in_service;
  IF was.serial IS NULL THEN
    RAISE EXCEPTION 'meter % is not in service at %', old_serial, swapped_at;
  END IF;
  PERFORM admin.retire_meter(old_serial, swapped_at);
  INSERT INTO registry.meters (serial) VALUES (new_serial) ON CONFLICT DO NOTHING;
  INSERT INTO registry.meter_swaps (old_serial, new_serial, swapped_at)
  VALUES (old_serial, new_serial, swapped_at);
  RETURN admin.change_meter(new_serial, swapped_at, was.endpoint_id, was.unit_id);
END
$$;

-- For the last reading and missed read at a unit's address.
CREATE INDEX readings_place_time
  ON store.readings (collector_id, endpoint_host, endpoint_port, unit_id, read_at);
CREATE INDEX missed_reads_place_time
  ON store.missed_reads (collector_id, endpoint_host, endpoint_port, unit_id, read_at);

-- A missed read counts for the meter that reported the serial on it or, when
-- no serial was read, for the meter registered at its address now.
-- contract: central/test/health.sql
CREATE VIEW health.meters AS
  WITH t AS (SELECT * FROM health.thresholds),
  m AS (
    SELECT m.serial, m.in_service, m.endpoint_id, m.unit_id, g.profile, e.collector_id,
           e.host, e.port, e.polled_by_other_system,
           m.in_service AND g.in_service AND e.in_service AND NOT e.polled_by_other_system
             AS expected,
           coalesce(g.interval_ms, e.interval_ms) * interval '1 millisecond' AS expected_interval,
           coalesce(
             (SELECT max(upper(x.period)) FROM registry.meter_history x
              WHERE x.serial = m.serial AND NOT x.in_service AND upper(x.period) <= now()),
             (SELECT min(x.valid_from) FROM registry.meter_versions x WHERE x.serial = m.serial))
             AS in_service_since,
           (SELECT max(r.read_at) FROM store.readings r WHERE r.meter_serial = m.serial)
             AS last_reading_at
    FROM registry.meter_history m
    JOIN registry.target_history g
      ON (g.endpoint_id, g.unit_id) = (m.endpoint_id, m.unit_id) AND g.period @> now()
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

-- Per registered target, as registered now: the meter placed there now, if
-- any, and the last reading and last missed read at its unit, whatever
-- serial they carry, at each address its endpoint had while in service. A
-- target is silent when neither came for meter_silent_intervals × its
-- interval while it was expected to be read.
-- contract: central/test/health.sql
CREATE VIEW health.targets AS
  WITH t AS (SELECT * FROM health.thresholds),
  g AS (
    SELECT g.endpoint_id, g.unit_id, g.in_service, g.profile, e.collector_id, e.host, e.port,
           e.polled_by_other_system,
           g.in_service AND e.in_service AND NOT e.polled_by_other_system AS expected,
           coalesce(g.interval_ms, e.interval_ms) * interval '1 millisecond' AS expected_interval,
           coalesce(
             (SELECT max(upper(x.period)) FROM registry.target_history x
              WHERE (x.endpoint_id, x.unit_id) = (g.endpoint_id, g.unit_id) AND NOT x.in_service
                AND upper(x.period) <= now()),
             (SELECT min(x.valid_from) FROM registry.target_versions x
              WHERE (x.endpoint_id, x.unit_id) = (g.endpoint_id, g.unit_id)))
             AS in_service_since,
           (SELECT m.serial FROM registry.meter_history m
            WHERE (m.endpoint_id, m.unit_id) = (g.endpoint_id, g.unit_id) AND m.in_service
              AND m.period @> now()) AS serial
    FROM registry.target_history g
    JOIN registry.endpoint_history e ON e.endpoint_id = g.endpoint_id AND e.period @> now()
    WHERE g.period @> now()
  ),
  last AS (
    SELECT g.endpoint_id, g.unit_id, max(r.read_at) AS reading_at, max(x.read_at) AS missed_at
    FROM g
    JOIN registry.endpoint_history a ON a.endpoint_id = g.endpoint_id AND a.in_service
    CROSS JOIN LATERAL (
      SELECT max(r.read_at) AS read_at FROM store.readings r
      WHERE (r.collector_id, r.endpoint_host, r.endpoint_port, r.unit_id)
            = (a.collector_id, a.host, a.port, g.unit_id)
        AND r.read_at >= lower(a.period) AND (upper(a.period) IS NULL OR r.read_at < upper(a.period))
    ) r
    CROSS JOIN LATERAL (
      SELECT max(x.read_at) AS read_at FROM store.missed_reads x
      WHERE (x.collector_id, x.endpoint_host, x.endpoint_port, x.unit_id)
            = (a.collector_id, a.host, a.port, g.unit_id)
        AND x.read_at >= lower(a.period) AND (upper(a.period) IS NULL OR x.read_at < upper(a.period))
    ) x
    GROUP BY g.endpoint_id, g.unit_id
  )
  SELECT g.endpoint_id, g.unit_id, g.in_service, g.collector_id, g.host, g.port, g.profile,
         g.serial, g.polled_by_other_system, g.expected, g.expected_interval, g.in_service_since,
         l.reading_at AS last_reading_at, l.missed_at AS last_missed_read_at,
         g.expected
           AND greatest(l.reading_at, l.missed_at, g.in_service_since)
               < now() - t.meter_silent_intervals * g.expected_interval AS silent
  FROM g
  CROSS JOIN t
  LEFT JOIN last l USING (endpoint_id, unit_id);

-- As in 0008_serial_read.sql.
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
-- contract: central/test/health.sql, central/test/clock.sql, central/test/energy.sql,
--   central/test/endpoints.sql
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

GRANT SELECT ON health.meters, health.targets, health.misplaced_serials, health.problems
  TO monitor;

-- migrate:down
-- Forward only: the registry's history is never dropped. Undo with a new migration.
