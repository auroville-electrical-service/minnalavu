-- migrate:up

-- Register a collector: its row and a role of its own, which the collector's
-- token names (central/bin/collector-token).
-- contract: central/test/grants.sql
CREATE FUNCTION admin.create_collector(collector_id text) RETURNS name
LANGUAGE plpgsql AS $$
DECLARE
  r name;
BEGIN
  INSERT INTO store.collectors (id) VALUES (collector_id) RETURNING role INTO r;
  EXECUTE format('CREATE ROLE %I NOLOGIN', r);
  EXECUTE format('GRANT collector TO %I WITH INHERIT TRUE, SET FALSE', r);
  EXECUTE format('GRANT %I TO authenticator WITH INHERIT FALSE, SET TRUE', r);
  RETURN r;
END
$$;

-- migrate:down
-- Forward only: a rollback would drop raw data. Undo with a new migration.
