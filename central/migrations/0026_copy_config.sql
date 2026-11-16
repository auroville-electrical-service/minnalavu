-- migrate:up

-- What the polling config says about copying meters' stored entries: per
-- endpoint, whether to copy (off unless switched on), and per collector, the
-- window of its local wall clock to copy in. Both effective-dated, as the
-- rest of the registry.

-- Endpoints registered before copying existed copy nothing.
-- contract: central/test/registry.sql, central/test/collector_config.sql
ALTER TABLE registry.endpoint_versions ADD COLUMN copy boolean NOT NULL DEFAULT false;
ALTER TABLE registry.endpoint_versions ALTER COLUMN copy DROP DEFAULT;
COMMENT ON COLUMN registry.endpoint_versions.copy IS
  'Copy its meters'' stored entries within its collector''s copy window.';

CREATE OR REPLACE VIEW registry.endpoint_history AS
  SELECT v.endpoint_id, v.valid_from, lead(v.valid_from) OVER w AS valid_to,
         tstzrange(v.valid_from, lead(v.valid_from) OVER w) AS period,
         v.in_service, v.collector_id, v.host, v.port, v.framing, v.polled_by_other_system,
         v.timeout_ms, v.max_timeouts, v.retries, v.busy_backoff_ms,
         v.reconnect_backoff_min_ms, v.reconnect_backoff_max_ms, v.interval_ms,
         v.version_id, v.recorded_at, v.copy
  FROM (
    SELECT DISTINCT ON (endpoint_id, valid_from) *
    FROM registry.endpoint_versions
    ORDER BY endpoint_id, valid_from, version_id DESC
  ) v
  WINDOW w AS (PARTITION BY v.endpoint_id ORDER BY v.valid_from);

DROP FUNCTION admin.register_endpoint(
  text, timestamptz, text, text, integer, registry.framing, boolean, integer, integer, integer,
  integer, integer, integer, integer);
DROP FUNCTION admin.change_endpoint(
  text, timestamptz, text, text, integer, registry.framing, boolean, integer, integer, integer,
  integer, integer, integer, integer);

-- copy has no default here: a change states the endpoint's whole state, so
-- leaving it out cannot switch copying off unseen.
-- contract: central/test/registry.sql
CREATE FUNCTION admin.change_endpoint(
  endpoint_id text, valid_from timestamptz, collector_id text, host text, port integer,
  framing registry.framing, polled_by_other_system boolean, timeout_ms integer,
  max_timeouts integer, retries integer, busy_backoff_ms integer,
  reconnect_backoff_min_ms integer, reconnect_backoff_max_ms integer, interval_ms integer,
  copy boolean
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
     reconnect_backoff_min_ms, reconnect_backoff_max_ms, interval_ms, copy)
  VALUES
    (endpoint_id, valid_from, true, collector_id, host, port, framing,
     polled_by_other_system, timeout_ms, max_timeouts, retries, busy_backoff_ms,
     reconnect_backoff_min_ms, reconnect_backoff_max_ms, interval_ms, copy)
  RETURNING version_id INTO v;
  PERFORM registry.check_history();
  RETURN v;
END
$$;
COMMENT ON FUNCTION admin.change_endpoint IS
  'An endpoint''s whole state from valid_from: readdress it, move it to another collector, change how it is polled, switch copying on or off, or correct an earlier row.';

-- A new endpoint copies nothing unless copy says so.
-- contract: central/test/registry.sql
CREATE FUNCTION admin.register_endpoint(
  endpoint_id text, valid_from timestamptz, collector_id text, host text, port integer,
  framing registry.framing, polled_by_other_system boolean, timeout_ms integer,
  max_timeouts integer, retries integer, busy_backoff_ms integer,
  reconnect_backoff_min_ms integer, reconnect_backoff_max_ms integer, interval_ms integer,
  copy boolean DEFAULT false
) RETURNS bigint
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO registry.endpoints (id) VALUES (endpoint_id);
  RETURN admin.change_endpoint(
    endpoint_id, valid_from, collector_id, host, port, framing, polled_by_other_system,
    timeout_ms, max_timeouts, retries, busy_backoff_ms, reconnect_backoff_min_ms,
    reconnect_backoff_max_ms, interval_ms, copy);
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
     reconnect_backoff_min_ms, reconnect_backoff_max_ms, interval_ms, copy)
  SELECT h.endpoint_id, valid_from, false, h.collector_id, h.host, h.port, h.framing,
         h.polled_by_other_system, h.timeout_ms, h.max_timeouts, h.retries, h.busy_backoff_ms,
         h.reconnect_backoff_min_ms, h.reconnect_backoff_max_ms, h.interval_ms, h.copy
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

-- A collector's copy window, in its local wall-clock time, from valid_from;
-- of rows sharing a valid_from, the one recorded last holds. Times are whole
-- minutes, as the polling config carries them; an end before the start
-- crosses midnight.
-- contract: central/test/config.sql, central/test/collector_config.sql
CREATE TABLE registry.copy_window_versions (
  version_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  collector_id text NOT NULL REFERENCES store.collectors (id),
  valid_from timestamptz NOT NULL CHECK (isfinite(valid_from)),
  recorded_at timestamptz NOT NULL DEFAULT now(),
  start_time time NOT NULL CHECK (start_time < time '24:00' AND extract(second FROM start_time) = 0),
  end_time time NOT NULL CHECK (end_time < time '24:00' AND extract(second FROM end_time) = 0),
  CHECK (start_time <> end_time)
);
CREATE INDEX ON registry.copy_window_versions (collector_id, valid_from);
CREATE TRIGGER refuse_change BEFORE UPDATE OR DELETE ON registry.copy_window_versions
  FOR EACH ROW EXECUTE FUNCTION registry.refuse_change();
CREATE TRIGGER refuse_truncate BEFORE TRUNCATE ON registry.copy_window_versions
  FOR EACH STATEMENT EXECUTE FUNCTION registry.refuse_change();

CREATE VIEW registry.copy_window_history AS
  SELECT v.collector_id, v.valid_from, lead(v.valid_from) OVER w AS valid_to,
         tstzrange(v.valid_from, lead(v.valid_from) OVER w) AS period,
         v.start_time, v.end_time, v.version_id, v.recorded_at
  FROM (
    SELECT DISTINCT ON (collector_id, valid_from) *
    FROM registry.copy_window_versions
    ORDER BY collector_id, valid_from, version_id DESC
  ) v
  WINDOW w AS (PARTITION BY v.collector_id ORDER BY v.valid_from);

-- contract: central/test/collector_config.sql
CREATE FUNCTION admin.set_copy_window(
  collector_id text, valid_from timestamptz, start_time time, end_time time
) RETURNS bigint
LANGUAGE sql AS $$
  INSERT INTO registry.copy_window_versions (collector_id, valid_from, start_time, end_time)
  VALUES (collector_id, valid_from, start_time, end_time)
  RETURNING version_id
$$;
COMMENT ON FUNCTION admin.set_copy_window IS
  'A collector''s copy window from valid_from, in its local wall-clock time; a collector with none in force is served a config without one, which it refuses.';

-- The collectors registered before copying existed copy from 02:00 to 03:00.
INSERT INTO registry.copy_window_versions (collector_id, valid_from, start_time, end_time)
SELECT id, now(), time '02:00', time '03:00' FROM store.collectors;

-- As in 0021_collector_config.sql, with each endpoint's copy and the
-- collector's copy window in force now, left out when it has none.
-- contract: central/test/collector_config.sql
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
             'copy', e.copy,
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
               '[]')) AS endpoint
    FROM registry.endpoint_history e
    WHERE e.collector_id = collector AND e.in_service AND e.period @> now()
  ) x
$$;

-- migrate:down
-- Forward only: the registry's history is never dropped. Undo with a new migration.
