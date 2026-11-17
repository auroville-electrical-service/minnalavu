-- migrate:up

-- What the polling config says about when a meter is read: its rounds fall
-- on its collector's local wall clock at multiples of its interval from
-- midnight, so an interval divides a day; and after a round that gave no
-- reading, it is read again after its retry interval until it answers. The
-- retry interval is per endpoint, with a target's own in place of it where
-- the target has one, as the interval is; both effective-dated, as the rest
-- of the registry.

-- An interval that does not divide a day has no slots from midnight to put
-- rounds on. Rows are immutable, so one already held stops the migration
-- here rather than being corrected unseen.
DO $$
DECLARE
  bad text;
BEGIN
  SELECT string_agg(DISTINCT format('%s %s', x.what, x.interval_ms), ', ')
    INTO bad
    FROM (SELECT 'endpoint ' || endpoint_id AS what, interval_ms
            FROM registry.endpoint_versions
          UNION ALL
          SELECT format('target %s unit %s', endpoint_id, unit_id), interval_ms
            FROM registry.target_versions WHERE interval_ms IS NOT NULL) x
   WHERE 86400000 % x.interval_ms <> 0;
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'intervals that do not divide a day (86400000 ms): %', bad
      USING HINT = 'Polling rounds fall on slots from local midnight; decide each interval with the owner before migrating.';
  END IF;
END
$$;

-- contract: central/test/config.sql, central/test/registry.sql
-- CASE, so that an interval of 0 fails its range check, not with a division by zero.
ALTER TABLE registry.endpoint_versions ADD CONSTRAINT interval_divides_a_day
  CHECK (CASE WHEN interval_ms > 0 THEN 86400000 % interval_ms = 0 END);
ALTER TABLE registry.target_versions ADD CONSTRAINT interval_divides_a_day
  CHECK (CASE WHEN interval_ms > 0 THEN 86400000 % interval_ms = 0 END);

-- contract: central/test/registry.sql, central/test/collector_config.sql
-- Endpoints registered before retries existed retry after 30 minutes.
ALTER TABLE registry.endpoint_versions
  ADD COLUMN retry_ms integer NOT NULL DEFAULT 1800000 CHECK (retry_ms BETWEEN 1 AND 86400000);
ALTER TABLE registry.endpoint_versions ALTER COLUMN retry_ms DROP DEFAULT;
COMMENT ON COLUMN registry.endpoint_versions.retry_ms IS
  'How soon a meter that gave no reading in a round is read again, until it answers; a target''s own retry_ms takes its place.';

ALTER TABLE registry.target_versions
  ADD COLUMN retry_ms integer CHECK (retry_ms BETWEEN 1 AND 86400000);
COMMENT ON COLUMN registry.target_versions.retry_ms IS
  'How soon the unit is read again after a round that gave no reading; NULL means its endpoint''s, as in the polling config.';

CREATE OR REPLACE VIEW registry.endpoint_history AS
  SELECT v.endpoint_id, v.valid_from, lead(v.valid_from) OVER w AS valid_to,
         tstzrange(v.valid_from, lead(v.valid_from) OVER w) AS period,
         v.in_service, v.collector_id, v.host, v.port, v.framing, v.polled_by_other_system,
         v.timeout_ms, v.max_timeouts, v.retries, v.busy_backoff_ms,
         v.reconnect_backoff_min_ms, v.reconnect_backoff_max_ms, v.interval_ms,
         v.version_id, v.recorded_at, v.copy, v.retry_ms
  FROM (
    SELECT DISTINCT ON (endpoint_id, valid_from) *
    FROM registry.endpoint_versions
    ORDER BY endpoint_id, valid_from, version_id DESC
  ) v
  WINDOW w AS (PARTITION BY v.endpoint_id ORDER BY v.valid_from);

CREATE OR REPLACE VIEW registry.target_history AS
  SELECT v.endpoint_id, v.unit_id, v.valid_from, lead(v.valid_from) OVER w AS valid_to,
         tstzrange(v.valid_from, lead(v.valid_from) OVER w) AS period,
         v.in_service, v.profile, v.interval_ms, v.version_id, v.recorded_at, v.retry_ms
  FROM (
    SELECT DISTINCT ON (endpoint_id, unit_id, valid_from) *
    FROM registry.target_versions
    ORDER BY endpoint_id, unit_id, valid_from, version_id DESC
  ) v
  WINDOW w AS (PARTITION BY v.endpoint_id, v.unit_id ORDER BY v.valid_from);

DROP FUNCTION admin.register_endpoint(
  text, timestamptz, text, text, integer, registry.framing, boolean, integer, integer, integer,
  integer, integer, integer, integer, boolean);
DROP FUNCTION admin.change_endpoint(
  text, timestamptz, text, text, integer, registry.framing, boolean, integer, integer, integer,
  integer, integer, integer, integer, boolean);
DROP FUNCTION admin.register_target(text, integer, timestamptz, text, integer);
DROP FUNCTION admin.change_target(text, integer, timestamptz, text, integer);

-- contract: central/test/registry.sql
-- retry_ms has no default: a change states the endpoint's whole state.
CREATE FUNCTION admin.change_endpoint(
  endpoint_id text, valid_from timestamptz, collector_id text, host text, port integer,
  framing registry.framing, polled_by_other_system boolean, timeout_ms integer,
  max_timeouts integer, retries integer, busy_backoff_ms integer,
  reconnect_backoff_min_ms integer, reconnect_backoff_max_ms integer, interval_ms integer,
  retry_ms integer, copy boolean
) RETURNS bigint
LANGUAGE plpgsql AS $$
#variable_conflict use_variable
DECLARE
  v bigint;
BEGIN
  IF NOT EXISTS (SELECT FROM registry.endpoints e WHERE e.id = endpoint_id) THEN
    RAISE EXCEPTION 'endpoint % is not registered', endpoint_id
      USING HINT = 'Register it with admin.register_endpoint.';
  END IF;
  INSERT INTO registry.endpoint_versions
    (endpoint_id, valid_from, in_service, collector_id, host, port, framing,
     polled_by_other_system, timeout_ms, max_timeouts, retries, busy_backoff_ms,
     reconnect_backoff_min_ms, reconnect_backoff_max_ms, interval_ms, retry_ms, copy)
  VALUES
    (endpoint_id, valid_from, true, collector_id, host, port, framing,
     polled_by_other_system, timeout_ms, max_timeouts, retries, busy_backoff_ms,
     reconnect_backoff_min_ms, reconnect_backoff_max_ms, interval_ms, retry_ms, copy)
  RETURNING version_id INTO v;
  PERFORM registry.check_history();
  RETURN v;
END
$$;
COMMENT ON FUNCTION admin.change_endpoint IS
  'An endpoint''s whole state from valid_from: readdress it, move it to another collector, change how it is polled, switch copying on or off, or correct an earlier row. interval_ms divides a day.';

-- contract: central/test/registry.sql
-- A new endpoint copies nothing unless copy says so.
CREATE FUNCTION admin.register_endpoint(
  endpoint_id text, valid_from timestamptz, collector_id text, host text, port integer,
  framing registry.framing, polled_by_other_system boolean, timeout_ms integer,
  max_timeouts integer, retries integer, busy_backoff_ms integer,
  reconnect_backoff_min_ms integer, reconnect_backoff_max_ms integer, interval_ms integer,
  retry_ms integer, copy boolean DEFAULT false
) RETURNS bigint
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO registry.endpoints (id) VALUES (endpoint_id);
  RETURN admin.change_endpoint(
    endpoint_id, valid_from, collector_id, host, port, framing, polled_by_other_system,
    timeout_ms, max_timeouts, retries, busy_backoff_ms, reconnect_backoff_min_ms,
    reconnect_backoff_max_ms, interval_ms, retry_ms, copy);
END
$$;

-- contract: central/test/registry.sql
CREATE OR REPLACE FUNCTION admin.retire_endpoint(endpoint_id text, valid_from timestamptz)
RETURNS bigint
LANGUAGE plpgsql AS $$
#variable_conflict use_variable
DECLARE
  v bigint;
BEGIN
  INSERT INTO registry.endpoint_versions
    (endpoint_id, valid_from, in_service, collector_id, host, port, framing,
     polled_by_other_system, timeout_ms, max_timeouts, retries, busy_backoff_ms,
     reconnect_backoff_min_ms, reconnect_backoff_max_ms, interval_ms, retry_ms, copy)
  SELECT h.endpoint_id, valid_from, false, h.collector_id, h.host, h.port, h.framing,
         h.polled_by_other_system, h.timeout_ms, h.max_timeouts, h.retries, h.busy_backoff_ms,
         h.reconnect_backoff_min_ms, h.reconnect_backoff_max_ms, h.interval_ms, h.retry_ms,
         h.copy
    FROM registry.endpoint_history h
   WHERE h.endpoint_id = endpoint_id AND h.period @> valid_from AND h.in_service
  RETURNING version_id INTO v;
  IF v IS NULL THEN
    RAISE EXCEPTION 'endpoint % is not in service at %', endpoint_id, valid_from;
  END IF;
  PERFORM registry.check_history();
  RETURN v;
END
$$;

-- contract: central/test/registry.sql
-- retry_ms is required, NULL for the endpoint's, as interval_ms is.
CREATE FUNCTION admin.change_target(
  endpoint_id text, unit_id integer, valid_from timestamptz, profile text, interval_ms integer,
  retry_ms integer
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
    (endpoint_id, unit_id, valid_from, in_service, profile, interval_ms, retry_ms)
  VALUES (endpoint_id, unit_id, valid_from, true, profile, interval_ms, retry_ms)
  RETURNING version_id INTO v;
  PERFORM registry.check_history();
  RETURN v;
END
$$;
COMMENT ON FUNCTION admin.change_target IS
  'A target''s whole state from valid_from: its profile, its interval and its retry interval (NULL: its endpoint''s), or a correction of an earlier row. interval_ms divides a day.';

-- contract: central/test/registry.sql
CREATE FUNCTION admin.register_target(
  endpoint_id text, unit_id integer, valid_from timestamptz, profile text, interval_ms integer,
  retry_ms integer
) RETURNS bigint
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO registry.targets (endpoint_id, unit_id) VALUES (endpoint_id, unit_id);
  RETURN admin.change_target(endpoint_id, unit_id, valid_from, profile, interval_ms, retry_ms);
END
$$;

-- contract: central/test/registry.sql
CREATE OR REPLACE FUNCTION admin.retire_target(endpoint_id text, unit_id integer, valid_from timestamptz)
RETURNS bigint
LANGUAGE plpgsql AS $$
#variable_conflict use_variable
DECLARE
  v bigint;
BEGIN
  INSERT INTO registry.target_versions
    (endpoint_id, unit_id, valid_from, in_service, profile, interval_ms, retry_ms)
  SELECT h.endpoint_id, h.unit_id, valid_from, false, h.profile, h.interval_ms, h.retry_ms
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

-- contract: central/test/collector_config.sql
-- As in 0026_copy_config.sql, with each endpoint's retry_ms and a target's
-- own where it has one.
CREATE OR REPLACE FUNCTION registry.collector_config(collector text) RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_strip_nulls(jsonb_build_object(
    'schema_version', 1,
    'copy_window',
      (SELECT jsonb_build_object('start', to_char(w.start_time, 'HH24:MI'),
                                 'end', to_char(w.end_time, 'HH24:MI'))
       FROM registry.copy_window_history w
       WHERE w.collector_id = collector AND w.period @> now()),
    'endpoints', coalesce(jsonb_agg(x.endpoint ORDER BY x.host COLLATE "C", x.port), '[]')))
  FROM (
    SELECT e.host, e.port, jsonb_build_object(
             'host', e.host, 'port', e.port, 'framing', e.framing,
             'max_timeouts', e.max_timeouts,
             'polled_by_other_system', e.polled_by_other_system,
             'timeout_ms', e.timeout_ms, 'retries', e.retries,
             'busy_backoff_ms', e.busy_backoff_ms,
             'reconnect_backoff_ms', jsonb_build_object('min', e.reconnect_backoff_min_ms,
                                                        'max', e.reconnect_backoff_max_ms),
             'interval_ms', e.interval_ms,
             'retry_ms', e.retry_ms,
             'copy', e.copy,
             'meters', coalesce(
               (SELECT jsonb_agg(jsonb_build_object('unit_id', g.unit_id, 'serial', m.serial,
                                                    'profile', g.profile,
                                                    'interval_ms', g.interval_ms,
                                                    'retry_ms', g.retry_ms)
                                 ORDER BY g.unit_id)
                FROM registry.target_history g
                LEFT JOIN registry.meter_history m
                  ON (m.endpoint_id, m.unit_id) = (g.endpoint_id, g.unit_id)
                 AND m.in_service AND m.period @> now()
                WHERE g.endpoint_id = e.endpoint_id AND g.in_service AND g.period @> now()),
               '[]')) AS endpoint
    FROM registry.endpoint_history e
    WHERE e.collector_id = collector AND e.in_service AND e.period @> now()
  ) x
$$;

-- migrate:down
-- Forward only: the registry's history is never dropped. Undo with a new migration.
