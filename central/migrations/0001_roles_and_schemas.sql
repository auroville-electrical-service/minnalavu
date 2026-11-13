-- migrate:up

-- Roles belong to the cluster: created only if missing, since the SQL tests
-- migrate a second database on it.
-- contract: central/test/grants.sql
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'authenticator') THEN
    -- LOGIN and its password are set outside the migrations (central/README.md).
    CREATE ROLE authenticator NOLOGIN NOINHERIT;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'collector') THEN
    CREATE ROLE collector NOLOGIN;
  END IF;
END
$$;

CREATE EXTENSION IF NOT EXISTS timescaledb;

-- contract: central/test/grants.sql
REVOKE ALL ON SCHEMA public FROM PUBLIC;
DO $$
BEGIN
  EXECUTE format('REVOKE TEMPORARY ON DATABASE %I FROM PUBLIC', current_database());
END
$$;
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

CREATE SCHEMA store;
COMMENT ON SCHEMA store IS 'The data. No role PostgREST uses has any privilege here.';

CREATE SCHEMA api;
COMMENT ON SCHEMA api IS 'What PostgREST exposes (db-schemas = api).';
GRANT USAGE ON SCHEMA api TO collector;

CREATE SCHEMA admin;
COMMENT ON SCHEMA admin IS 'Functions for the operator, run as the database owner.';

-- migrate:down
-- Forward only: a rollback would drop raw data. Undo with a new migration.
