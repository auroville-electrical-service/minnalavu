-- migrate:up

-- The device registry: where each endpoint and meter sits and how it is polled,
-- from when. Effective-dated and append-only: a version row is the whole state
-- from its valid_from until the next row's; of rows sharing a valid_from, the
-- one recorded last (highest version_id) holds.
-- Meters are identified by serial, with no foreign key from readings, so
-- readings from an unregistered meter are kept.
-- contract: central/test/registry.sql

CREATE SCHEMA registry;
COMMENT ON SCHEMA registry IS
  'What is installed where, from when. Written only through admin functions, and only by adding rows.';

CREATE TYPE registry.framing AS ENUM ('tcp', 'rtu_over_tcp');

CREATE TABLE registry.endpoints (
  id text PRIMARY KEY CHECK (id ~ '^[a-z][a-z0-9_]{0,39}$'),
  created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE registry.endpoints IS
  'One row per endpoint: an IP address and port in front of an RS-485 chain.';

-- Polling settings and ranges as in alavi/lib/alavi/config/endpoint.ex.
CREATE TABLE registry.endpoint_versions (
  version_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  endpoint_id text NOT NULL REFERENCES registry.endpoints (id),
  valid_from timestamptz NOT NULL CHECK (isfinite(valid_from)),
  recorded_at timestamptz NOT NULL DEFAULT now(),
  in_service boolean NOT NULL,
  collector_id text NOT NULL REFERENCES store.collectors (id),
  host text NOT NULL CHECK (host ~ '^[^[:space:][:cntrl:]]{1,253}$'),
  port integer NOT NULL CHECK (port BETWEEN 1 AND 65535),
  framing registry.framing NOT NULL,
  polled_by_other_system boolean NOT NULL,
  timeout_ms integer NOT NULL CHECK (timeout_ms BETWEEN 1 AND 86400000),
  max_timeouts integer CHECK (max_timeouts BETWEEN 1 AND 100),
  retries integer NOT NULL CHECK (retries BETWEEN 0 AND 10),
  busy_backoff_ms integer NOT NULL CHECK (busy_backoff_ms BETWEEN 0 AND 86400000),
  reconnect_backoff_min_ms integer NOT NULL CHECK (reconnect_backoff_min_ms BETWEEN 1 AND 86400000),
  reconnect_backoff_max_ms integer NOT NULL
    CHECK (reconnect_backoff_max_ms BETWEEN reconnect_backoff_min_ms AND 86400000),
  interval_ms integer NOT NULL CHECK (interval_ms BETWEEN 1 AND 86400000),
  -- RTU over TCP closes the connection on every timeout.
  CONSTRAINT max_timeouts_for_tcp_only CHECK ((framing = 'tcp') = (max_timeouts IS NOT NULL))
);
COMMENT ON COLUMN registry.endpoint_versions.polled_by_other_system IS
  'Another system (the existing monitoring server) polls this endpoint; collectors never connect to it.';
CREATE INDEX ON registry.endpoint_versions (endpoint_id, valid_from);

CREATE TABLE registry.meters (
  serial text PRIMARY KEY CHECK (serial ~ '^[^[:cntrl:]]{1,100}$'),
  created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE registry.meters IS
  'One row per meter, by the serial its readings carry.';

CREATE TABLE registry.meter_versions (
  version_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  serial text NOT NULL REFERENCES registry.meters (serial),
  valid_from timestamptz NOT NULL CHECK (isfinite(valid_from)),
  recorded_at timestamptz NOT NULL DEFAULT now(),
  in_service boolean NOT NULL,
  endpoint_id text NOT NULL REFERENCES registry.endpoints (id),
  unit_id smallint NOT NULL CHECK (unit_id BETWEEN 1 AND 247),
  -- A profile in contract/profiles/, by name.
  profile text NOT NULL CHECK (profile ~ '^[a-z][a-z0-9_]{0,39}$'),
  interval_ms integer CHECK (interval_ms BETWEEN 1 AND 86400000)
);
COMMENT ON COLUMN registry.meter_versions.interval_ms IS
  'How often the meter is read; NULL means its endpoint''s interval, as in the polling config.';
COMMENT ON COLUMN registry.meter_versions.in_service IS
  'false from the meter''s retirement on; the other columns then say where it was last.';
CREATE INDEX ON registry.meter_versions (serial, valid_from);
CREATE INDEX ON registry.meter_versions (endpoint_id);

CREATE TABLE registry.meter_swaps (
  old_serial text NOT NULL REFERENCES registry.meters (serial),
  new_serial text NOT NULL REFERENCES registry.meters (serial),
  swapped_at timestamptz NOT NULL CHECK (isfinite(swapped_at)),
  recorded_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (old_serial, new_serial, swapped_at),
  CHECK (old_serial <> new_serial)
);

-- contract: central/test/registry.sql
CREATE FUNCTION registry.refuse_change() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '% on %.% refused: registry history is never changed or deleted',
    TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME
    USING HINT = 'A change or correction is a new row, through the admin functions.';
END
$$;

DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['endpoints', 'endpoint_versions', 'meters', 'meter_versions', 'meter_swaps'] LOOP
    EXECUTE format(
      'CREATE TRIGGER refuse_change BEFORE UPDATE OR DELETE ON registry.%I
         FOR EACH ROW EXECUTE FUNCTION registry.refuse_change()', t);
    EXECUTE format(
      'CREATE TRIGGER refuse_truncate BEFORE TRUNCATE ON registry.%I
         FOR EACH STATEMENT EXECUTE FUNCTION registry.refuse_change()', t);
  END LOOP;
END
$$;

-- The state over each period [valid_from, valid_to); valid_to is NULL while open.
CREATE VIEW registry.endpoint_history AS
  SELECT v.endpoint_id, v.valid_from, lead(v.valid_from) OVER w AS valid_to,
         tstzrange(v.valid_from, lead(v.valid_from) OVER w) AS period,
         v.in_service, v.collector_id, v.host, v.port, v.framing, v.polled_by_other_system,
         v.timeout_ms, v.max_timeouts, v.retries, v.busy_backoff_ms,
         v.reconnect_backoff_min_ms, v.reconnect_backoff_max_ms, v.interval_ms,
         v.version_id, v.recorded_at
  FROM (
    SELECT DISTINCT ON (endpoint_id, valid_from) *
    FROM registry.endpoint_versions
    ORDER BY endpoint_id, valid_from, version_id DESC
  ) v
  WINDOW w AS (PARTITION BY v.endpoint_id ORDER BY v.valid_from);

CREATE VIEW registry.meter_history AS
  SELECT v.serial, v.valid_from, lead(v.valid_from) OVER w AS valid_to,
         tstzrange(v.valid_from, lead(v.valid_from) OVER w) AS period,
         v.in_service, v.endpoint_id, v.unit_id, v.profile, v.interval_ms,
         v.version_id, v.recorded_at
  FROM (
    SELECT DISTINCT ON (serial, valid_from) *
    FROM registry.meter_versions
    ORDER BY serial, valid_from, version_id DESC
  ) v
  WINDOW w AS (PARTITION BY v.serial ORDER BY v.valid_from);

-- Checked after every admin change, over the whole history, so a back-dated
-- row is judged against what follows it. Raises exclusion_violation (23P01).
-- contract: central/test/registry.sql
CREATE FUNCTION registry.check_history() RETURNS void
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
    SELECT format('meters %s and %s both have unit id %s on endpoint %s from %s',
                  a.serial, b.serial, a.unit_id, a.endpoint_id,
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
    SELECT format('meter %s is in service on endpoint %s from %s, when the endpoint is not',
                  m.serial, m.endpoint_id, lower(m.period))
      INTO conflict
      FROM registry.meter_history m
     WHERE m.in_service
       AND (lower(m.period) < (SELECT min(e.valid_from) FROM registry.endpoint_versions e
                               WHERE e.endpoint_id = m.endpoint_id)
            OR EXISTS (SELECT FROM registry.endpoint_history e
                       WHERE e.endpoint_id = m.endpoint_id AND NOT e.in_service
                         AND e.period && m.period))
     LIMIT 1;
  END IF;
  IF conflict IS NOT NULL THEN
    RAISE EXCEPTION 'registry change refused: %', conflict
      USING ERRCODE = 'exclusion_violation',
            HINT = 'Move or retire what is in the way first, from the same time.';
  END IF;
END
$$;

-- Admin functions: each adds one version row holding from valid_from (which
-- may be in the past), then runs registry.check_history. Call them with named
-- arguments:
--   SELECT admin.retire_meter(serial => 'X', valid_from => '2026-11-01T00:00Z');
-- contract: central/test/registry.sql

CREATE FUNCTION admin.change_endpoint(
  endpoint_id text, valid_from timestamptz, collector_id text, host text, port integer,
  framing registry.framing, polled_by_other_system boolean, timeout_ms integer,
  max_timeouts integer, retries integer, busy_backoff_ms integer,
  reconnect_backoff_min_ms integer, reconnect_backoff_max_ms integer, interval_ms integer
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
     reconnect_backoff_min_ms, reconnect_backoff_max_ms, interval_ms)
  VALUES
    (endpoint_id, valid_from, true, collector_id, host, port, framing,
     polled_by_other_system, timeout_ms, max_timeouts, retries, busy_backoff_ms,
     reconnect_backoff_min_ms, reconnect_backoff_max_ms, interval_ms)
  RETURNING version_id INTO v;
  PERFORM registry.check_history();
  RETURN v;
END
$$;
COMMENT ON FUNCTION admin.change_endpoint IS
  'An endpoint''s whole state from valid_from: readdress it, move it to another collector, change how it is polled, or correct an earlier row.';

CREATE FUNCTION admin.register_endpoint(
  endpoint_id text, valid_from timestamptz, collector_id text, host text, port integer,
  framing registry.framing, polled_by_other_system boolean, timeout_ms integer,
  max_timeouts integer, retries integer, busy_backoff_ms integer,
  reconnect_backoff_min_ms integer, reconnect_backoff_max_ms integer, interval_ms integer
) RETURNS bigint
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO registry.endpoints (id) VALUES (endpoint_id);
  RETURN admin.change_endpoint(
    endpoint_id, valid_from, collector_id, host, port, framing, polled_by_other_system,
    timeout_ms, max_timeouts, retries, busy_backoff_ms, reconnect_backoff_min_ms,
    reconnect_backoff_max_ms, interval_ms);
END
$$;

CREATE FUNCTION admin.retire_endpoint(endpoint_id text, valid_from timestamptz) RETURNS bigint
LANGUAGE plpgsql AS $$
#variable_conflict use_variable
DECLARE
  v bigint;
BEGIN
  INSERT INTO registry.endpoint_versions
    (endpoint_id, valid_from, in_service, collector_id, host, port, framing,
     polled_by_other_system, timeout_ms, max_timeouts, retries, busy_backoff_ms,
     reconnect_backoff_min_ms, reconnect_backoff_max_ms, interval_ms)
  SELECT h.endpoint_id, valid_from, false, h.collector_id, h.host, h.port, h.framing,
         h.polled_by_other_system, h.timeout_ms, h.max_timeouts, h.retries, h.busy_backoff_ms,
         h.reconnect_backoff_min_ms, h.reconnect_backoff_max_ms, h.interval_ms
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

CREATE FUNCTION admin.change_meter(
  serial text, valid_from timestamptz, endpoint_id text, unit_id integer, profile text,
  interval_ms integer
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
  INSERT INTO registry.meter_versions
    (serial, valid_from, in_service, endpoint_id, unit_id, profile, interval_ms)
  VALUES (serial, valid_from, true, endpoint_id, unit_id, profile, interval_ms)
  RETURNING version_id INTO v;
  PERFORM registry.check_history();
  RETURN v;
END
$$;
COMMENT ON FUNCTION admin.change_meter IS
  'A meter''s whole state from valid_from: move it, change its interval (NULL: its endpoint''s), or correct an earlier row.';

CREATE FUNCTION admin.register_meter(
  serial text, valid_from timestamptz, endpoint_id text, unit_id integer, profile text,
  interval_ms integer
) RETURNS bigint
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO registry.meters (serial) VALUES (serial);
  RETURN admin.change_meter(serial, valid_from, endpoint_id, unit_id, profile, interval_ms);
END
$$;

CREATE FUNCTION admin.retire_meter(serial text, valid_from timestamptz) RETURNS bigint
LANGUAGE plpgsql AS $$
#variable_conflict use_variable
DECLARE
  v bigint;
BEGIN
  INSERT INTO registry.meter_versions
    (serial, valid_from, in_service, endpoint_id, unit_id, profile, interval_ms)
  SELECT h.serial, valid_from, false, h.endpoint_id, h.unit_id, h.profile, h.interval_ms
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

-- The new meter may already be registered (a spare that was in service elsewhere).
CREATE FUNCTION admin.swap_meter(
  old_serial text, new_serial text, swapped_at timestamptz, profile text
) RETURNS bigint
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
  RETURN admin.change_meter(new_serial, swapped_at, was.endpoint_id, was.unit_id, profile,
                            was.interval_ms);
END
$$;

-- migrate:down
-- Forward only: the registry's history is never dropped. Undo with a new migration.
