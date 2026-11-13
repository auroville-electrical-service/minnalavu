-- What the roles PostgREST uses may do: call api.ingest, and nothing else;
-- and what monitor may do: read the health views, and nothing else.
-- Above all, no such role may read, change or delete raw readings.

\ir lib/assert.sql
\set basic `cat ../contract/fixtures/batch.v1.basic.json`

BEGIN;

SELECT admin.create_collector('sqltest_grants');

-- Every role PostgREST can act as: the one it logs in as and every role it
-- may switch to; and the collector group, whose privileges they inherit.
-- Roles belong to the cluster, so collectors registered in other databases on
-- it (the dev database) are here too.
CREATE TEMP VIEW postgrest_roles AS
  SELECT 'authenticator'::name AS role
  UNION SELECT 'collector'
  UNION SELECT m.roleid::regrole::name FROM pg_auth_members m
        WHERE m.member = (SELECT oid FROM pg_roles WHERE rolname = 'authenticator');

-- Our schemas: everything but the system's and TimescaleDB's own. TimescaleDB
-- lets every role read its catalog (hypertable and job metadata, no data);
-- PostgREST does not expose it.
CREATE TEMP VIEW user_schemas AS
  SELECT oid, nspname FROM pg_namespace
  WHERE nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
    AND nspname NOT LIKE 'pg_temp_%' AND nspname NOT LIKE 'pg_toast_temp_%'
    AND nspname NOT LIKE '\_timescaledb\_%' AND nspname NOT LIKE 'timescaledb\_%';

-- Our tables and views, and the chunks that hold the hypertables' rows. A
-- batch is ingested first so that chunks exist.
SELECT pg_temp.ingest_as('collector_sqltest_grants', :'basic');

CREATE TEMP VIEW user_relations AS
  SELECT c.oid, s.nspname, c.relname, c.relkind
  FROM pg_class c JOIN user_schemas s ON s.oid = c.relnamespace
  UNION
  SELECT c.oid, n.nspname, c.relname, c.relkind
  FROM pg_inherits i
  JOIN pg_class c ON c.oid = i.inhrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE i.inhparent IN ('store.readings'::regclass, 'store.missed_reads'::regclass);

SELECT pg_temp.ok(
  (SELECT count(*) FROM user_relations WHERE nspname = '_timescaledb_internal') >= 2,
  'the chunks of readings and missed_reads are among the tables checked');

CREATE TEMP VIEW collector_roles AS
  SELECT role FROM postgrest_roles WHERE role <> 'authenticator';

SELECT pg_temp.ok(
  (SELECT 'collector_sqltest_grants' IN (SELECT role FROM collector_roles)),
  'a registered collector''s role is among the roles checked');

SELECT pg_temp.is(
  (SELECT string_agg(role, '; ') FROM postgrest_roles
   WHERE role NOT IN ('authenticator', 'collector') AND role !~ '^collector_[a-z][a-z0-9_]*$'),
  NULL,
  'authenticator may switch only to collector roles');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s has %s on %s.%s', r.role, p, c.nspname, c.relname), '; ')
   FROM postgrest_roles r
   CROSS JOIN user_relations c
   CROSS JOIN unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'REFERENCES']) p
   WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
     AND has_any_column_privilege(r.role, c.oid, p)),
  NULL,
  'no PostgREST role may select, insert, update or reference any table or view, chunks included');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s has %s on %s.%s', r.role, p, c.nspname, c.relname), '; ')
   FROM postgrest_roles r
   CROSS JOIN user_relations c
   CROSS JOIN unnest(ARRAY['DELETE', 'TRUNCATE', 'TRIGGER']) p
   WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
     AND has_table_privilege(r.role, c.oid, p)),
  NULL,
  'no PostgREST role may delete from, truncate or add triggers to any table');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s has %s on %s.%s', r.role, p, c.nspname, c.relname), '; ')
   FROM postgrest_roles r
   CROSS JOIN user_relations c
   CROSS JOIN unnest(ARRAY['USAGE', 'SELECT', 'UPDATE']) p
   WHERE c.relkind = 'S' AND has_sequence_privilege(r.role, c.oid, p)),
  NULL,
  'no PostgREST role may use any sequence');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s may execute %s', r.role, f.oid::regprocedure), '; '
                     ORDER BY r.role)
   FROM postgrest_roles r
   CROSS JOIN pg_proc f
   JOIN pg_namespace n ON n.oid = f.pronamespace
   WHERE n.nspname IN ('store', 'api', 'admin', 'registry', 'health')
     AND has_function_privilege(r.role, f.oid, 'EXECUTE')),
  (SELECT string_agg(format('%s may execute api.ingest(jsonb)', role), '; ' ORDER BY role)
   FROM collector_roles),
  'the only function a PostgREST role may execute is api.ingest, and authenticator may not');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s has %s on schema %s', r.role, p, s.nspname), '; '
                     ORDER BY r.role, s.nspname, p)
   FROM postgrest_roles r
   CROSS JOIN user_schemas s
   CROSS JOIN unnest(ARRAY['USAGE', 'CREATE']) p
   WHERE has_schema_privilege(r.role, s.oid, p)),
  (SELECT string_agg(format('%s has USAGE on schema api', role), '; ' ORDER BY role)
   FROM collector_roles),
  'collectors may use only the api schema, and no PostgREST role may create anything in one');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s has %s', r.role, p), '; ')
   FROM postgrest_roles r
   CROSS JOIN unnest(ARRAY['CREATE', 'TEMPORARY']) p
   WHERE has_database_privilege(r.role, current_database(), p)),
  NULL,
  'no PostgREST role may create schemas or temporary tables');

SELECT pg_temp.is(
  (SELECT string_agg(f.oid::regprocedure::text, '; ')
   FROM pg_proc f WHERE f.pronamespace = 'api'::regnamespace),
  'api.ingest(jsonb)',
  'api holds one function, ingest');

SELECT pg_temp.is(
  (SELECT count(*) FROM pg_class WHERE relnamespace = 'api'::regnamespace),
  0::bigint,
  'api holds no tables or views');

SELECT pg_temp.is(
  (SELECT string_agg(m.roleid::regrole::text, '; ')
   FROM pg_auth_members m
   WHERE m.member = 'authenticator'::regrole AND (m.inherit_option OR NOT m.set_option)),
  NULL,
  'authenticator inherits nothing from the roles it may switch to');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s in %s', m.member::regrole, m.roleid::regrole), '; ')
   FROM pg_auth_members m
   WHERE m.roleid = 'collector'::regrole AND m.set_option),
  NULL,
  'no role may switch to the collector group role itself');

SELECT pg_temp.is(
  (SELECT string_agg(r.rolname, '; ')
   FROM pg_roles r
   WHERE r.rolname IN (SELECT role FROM collector_roles)
     AND (r.rolcanlogin OR r.rolsuper OR r.rolcreaterole OR r.rolcreatedb OR r.rolbypassrls)),
  NULL,
  'collector roles cannot log in and hold no special attribute');

SELECT pg_temp.ok(
  (SELECT NOT rolinherit AND NOT rolsuper AND NOT rolcreaterole AND NOT rolcreatedb
          AND NOT rolbypassrls
   FROM pg_roles WHERE rolname = 'authenticator'),
  'authenticator is NOINHERIT and holds no special attribute');

-- The same, by trying: each statement must be refused for lack of privilege.
-- (Which roles may be switched to is checked above, in pg_auth_members: SET
-- ROLE is judged against the session's login role, which here is the owner.)
SELECT pg_temp.is(pg_temp.sqlstate_as('collector_sqltest_grants', q), '42501',
                  'a collector is refused: ' || q)
FROM unnest(ARRAY[
  'SELECT * FROM store.readings',
  'SELECT * FROM store.missed_reads',
  'SELECT * FROM store.batches',
  'SELECT * FROM store.collectors',
  'SELECT * FROM registry.meter_versions',
  'SELECT * FROM registry.endpoint_history',
  $q$INSERT INTO store.readings VALUES ('S', 'r', now(), 1, 'Wh', '{1}', 'p', 'h', 1, 1, 'c', gen_random_uuid())$q$,
  $q$UPDATE store.readings SET value = 0$q$,
  $q$DELETE FROM store.readings$q$,
  $q$TRUNCATE store.readings$q$,
  $q$SELECT admin.create_collector('sqltest_intruder')$q$,
  $q$SELECT admin.retire_meter('SQLREG-0001', now())$q$,
  $q$SELECT store.check_batch('{}')$q$,
  $q$SELECT store.reject('x', 'y')$q$
]) q;

SELECT pg_temp.is(pg_temp.sqlstate_as('authenticator', q), '42501',
                  'authenticator is refused: ' || q)
FROM unnest(ARRAY[
  $q$SELECT api.ingest('{}')$q$,
  'SELECT * FROM store.readings',
  $q$DELETE FROM store.readings$q$
]) q;

-- The role monitor, and any login that is a member of it (the operator's, the
-- alert job's): it may read the health views, and nothing else.
CREATE TEMP VIEW monitor_roles AS
  SELECT 'monitor'::name AS role
  UNION SELECT m.member::regrole::name FROM pg_auth_members m
        WHERE m.roleid = (SELECT oid FROM pg_roles WHERE rolname = 'monitor');

SELECT pg_temp.is(
  (SELECT string_agg(c.relname::text, ', ' ORDER BY c.relname)
   FROM pg_class c WHERE c.relnamespace = 'health'::regnamespace AND c.relkind = 'v'),
  'collectors, meters, misplaced_serials, problems, thresholds, unregistered_serial_places, '
  || 'unregistered_serials',
  'health holds the seven health views');

SELECT pg_temp.is(
  (SELECT count(*) FROM pg_class c
   WHERE c.relnamespace = 'health'::regnamespace AND c.relkind <> 'v'),
  0::bigint,
  'health holds nothing but views');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s has %s on %s.%s', r.role, p, c.nspname, c.relname), '; '
                     ORDER BY r.role, c.nspname, c.relname, p)
   FROM monitor_roles r
   CROSS JOIN user_relations c
   CROSS JOIN unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'REFERENCES', 'DELETE', 'TRUNCATE',
                           'TRIGGER']) p
   WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
     AND CASE WHEN p IN ('SELECT', 'INSERT', 'UPDATE', 'REFERENCES')
              THEN has_any_column_privilege(r.role, c.oid, p)
              ELSE has_table_privilege(r.role, c.oid, p) END),
  (SELECT string_agg(format('%s has SELECT on health.%s', r.role, c.relname), '; '
                     ORDER BY r.role, c.relname)
   FROM monitor_roles r CROSS JOIN pg_class c WHERE c.relnamespace = 'health'::regnamespace),
  'monitor may select from the health views and do nothing else to any table or view, chunks included');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s has %s on %s.%s', r.role, p, c.nspname, c.relname), '; ')
   FROM monitor_roles r
   CROSS JOIN user_relations c
   CROSS JOIN unnest(ARRAY['USAGE', 'SELECT', 'UPDATE']) p
   WHERE c.relkind = 'S' AND has_sequence_privilege(r.role, c.oid, p)),
  NULL,
  'monitor may use no sequence');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s may execute %s', r.role, f.oid::regprocedure), '; ')
   FROM monitor_roles r
   CROSS JOIN pg_proc f
   JOIN pg_namespace n ON n.oid = f.pronamespace
   WHERE n.nspname IN ('store', 'api', 'admin', 'registry', 'health')
     AND has_function_privilege(r.role, f.oid, 'EXECUTE')),
  NULL,
  'monitor may execute none of our functions');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s has %s on schema %s', r.role, p, s.nspname), '; '
                     ORDER BY r.role, s.nspname, p)
   FROM monitor_roles r
   CROSS JOIN user_schemas s
   CROSS JOIN unnest(ARRAY['USAGE', 'CREATE']) p
   WHERE has_schema_privilege(r.role, s.oid, p)),
  (SELECT string_agg(format('%s has USAGE on schema health', role), '; ' ORDER BY role)
   FROM monitor_roles),
  'monitor may use only the health schema, and create nothing in it');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s has %s', r.role, p), '; ')
   FROM monitor_roles r
   CROSS JOIN unnest(ARRAY['CREATE', 'TEMPORARY']) p
   WHERE has_database_privilege(r.role, current_database(), p)),
  NULL,
  'monitor may not create schemas or temporary tables');

SELECT pg_temp.is(
  (SELECT string_agg(m.roleid::regrole::text, '; ')
   FROM pg_auth_members m WHERE m.member = 'monitor'::regrole),
  NULL,
  'monitor is a member of no other role');

SELECT pg_temp.is(
  (SELECT string_agg(r.rolname, '; ')
   FROM pg_roles r
   WHERE r.rolname IN (SELECT role FROM monitor_roles)
     AND (r.rolsuper OR r.rolcreaterole OR r.rolcreatedb OR r.rolbypassrls OR r.rolreplication
          OR (r.rolname = 'monitor' AND r.rolcanlogin))),
  NULL,
  'monitor cannot log in, and neither it nor its members hold a special attribute');

SELECT pg_temp.is(pg_temp.sqlstate_as('monitor', q), '00000', 'monitor may: ' || q)
FROM unnest(ARRAY[
  'SELECT * FROM health.problems',
  'SELECT * FROM health.collectors',
  'SELECT * FROM health.meters',
  'SELECT * FROM health.unregistered_serials',
  'SELECT * FROM health.unregistered_serial_places',
  'SELECT * FROM health.misplaced_serials',
  'SELECT * FROM health.thresholds'
]) q;

SELECT pg_temp.is(pg_temp.sqlstate_as('monitor', q), '42501', 'monitor is refused: ' || q)
FROM unnest(ARRAY[
  'SELECT * FROM store.readings',
  'SELECT * FROM store.uploads',
  'SELECT * FROM registry.meter_versions',
  'SELECT * FROM registry.meter_history',
  'SELECT * FROM registry.health_thresholds',
  $q$SELECT api.ingest('{}')$q$,
  $q$SELECT admin.set_health_thresholds('1 hour', 4, 0.8, '1 day')$q$,
  $q$SELECT admin.retire_meter('SQLREG-0001', now())$q$,
  $q$INSERT INTO registry.health_thresholds (collector_silent_after, meter_silent_intervals, backlog_near_capacity, lookback) VALUES ('1 hour', 4, 0.8, '1 day')$q$,
  $q$DELETE FROM store.readings$q$,
  'CREATE TABLE health.x (i int)',
  'CREATE TEMP TABLE x (i int)'
]) q;

ROLLBACK;
