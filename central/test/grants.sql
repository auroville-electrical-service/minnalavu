-- What the roles PostgREST uses may do: call api.ingest, and nothing else;
-- what monitor may do: read the health views, and nothing else; and what
-- minkanakku_staff may do: request a job and read the requests, and nothing
-- else. Above all, no such role may read, change or delete raw readings.

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
  'SELECT * FROM store.firmware_reads',
  'SELECT * FROM store.batches',
  'SELECT * FROM store.collectors',
  'SELECT * FROM registry.meter_versions',
  'SELECT * FROM registry.endpoint_history',
  'SELECT * FROM registry.targets',
  'SELECT * FROM registry.target_versions',
  'SELECT * FROM registry.target_history',
  'SELECT * FROM health.targets',
  $q$INSERT INTO store.readings VALUES ('S', 'r', now(), 1, 'p', 'h', 1, 1, 'c', gen_random_uuid(), 'P', 1)$q$,
  $q$UPDATE store.readings SET value = 0$q$,
  $q$DELETE FROM store.readings$q$,
  $q$TRUNCATE store.readings$q$,
  'SELECT * FROM store.profile_versions',
  'SELECT * FROM store.profile_registers',
  $q$INSERT INTO store.profile_versions (profile, version) VALUES ('elite_440', 99)$q$,
  $q$SELECT admin.load_profile('{"profile": "elite_440", "version": 99, "registers": []}')$q$,
  $q$INSERT INTO store.firmware_reads VALUES ('S', 'P', now(), 'a', 'b', 'c', '0B03', 'h', 1, 1, 'c', gen_random_uuid())$q$,
  $q$UPDATE store.firmware_reads SET software = 'x'$q$,
  $q$DELETE FROM store.firmware_reads$q$,
  $q$INSERT INTO store.clock_checks (collector_id, t1, t4, trigger, server, outcome, batch_id) VALUES ('sqltest_grants', now(), now(), 'daily', 'pool.ntp.org', 'timeout', gen_random_uuid())$q$,
  $q$UPDATE store.clock_checks SET server = 'x'$q$,
  $q$DELETE FROM store.clock_checks$q$,
  'SELECT * FROM store.clock_checks',
  'SELECT * FROM store.clock_offsets',
  'SELECT * FROM store.clock_check_references',
  'SELECT * FROM store.upload_clock_offsets',
  'SELECT * FROM store.ungrounded_readings',
  'SELECT * FROM store.energy_drops',
  $q$INSERT INTO store.latency_days (collector_id, endpoint_host, endpoint_port, unit_id, day, poller_started_at, buckets_version, retries, timeouts, max_ms, buckets, batch_id) VALUES ('sqltest_grants', 'h', 1, 1, '2026-11-01', now(), 1, 0, 0, NULL, '{0,0}', gen_random_uuid())$q$,
  $q$UPDATE store.latency_days SET retries = 0$q$,
  $q$DELETE FROM store.latency_days$q$,
  'SELECT * FROM store.latency_days',
  'SELECT * FROM store.latency_bucket_versions',
  'SELECT * FROM store.latency_meter_days',
  'SELECT * FROM store.latency_endpoint_days',
  'SELECT * FROM health.endpoint_latency',
  $q$INSERT INTO store.latency_bucket_versions (version, bounds_ms) VALUES (99, '{1}')$q$,
  $q$SELECT admin.load_latency_buckets('{"version": 99, "bounds_ms": [1]}')$q$,
  $q$SELECT admin.create_collector('sqltest_intruder')$q$,
  $q$SELECT admin.retire_meter('SQLREG-0001', now())$q$,
  $q$SELECT admin.register_target('e', 1, now(), 'elite_440', NULL)$q$,
  $q$SELECT admin.change_target('e', 1, now(), 'elite_440', NULL)$q$,
  $q$SELECT admin.retire_target('e', 1, now())$q$,
  $q$INSERT INTO registry.target_versions (endpoint_id, unit_id, valid_from, in_service, profile) VALUES ('e', 1, now(), true, 'elite_440')$q$,
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
  'collector_clocks, collectors, endpoint_latency, endpoints, energy_drops, meter_firmware, meters, '
  || 'misplaced_serials, place_serials, problems, targets, thresholds, unregistered_serial_places, '
  || 'unregistered_serials',
  'health holds the fourteen health views');

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
  'SELECT * FROM health.place_serials',
  'SELECT * FROM health.collector_clocks',
  'SELECT * FROM health.meter_firmware',
  'SELECT * FROM health.energy_drops',
  'SELECT * FROM health.endpoints',
  'SELECT * FROM health.endpoint_latency',
  'SELECT * FROM health.targets',
  'SELECT * FROM health.thresholds'
]) q;

SELECT pg_temp.is(pg_temp.sqlstate_as('monitor', q), '42501', 'monitor is refused: ' || q)
FROM unnest(ARRAY[
  'SELECT * FROM store.readings',
  'SELECT * FROM store.uploads',
  'SELECT * FROM store.firmware_reads',
  'SELECT * FROM store.clock_checks',
  'SELECT * FROM store.clock_offsets',
  'SELECT * FROM store.clock_check_references',
  'SELECT * FROM store.upload_clock_offsets',
  'SELECT * FROM store.ungrounded_readings',
  'SELECT * FROM store.energy_drops',
  'SELECT * FROM store.latency_days',
  'SELECT * FROM store.latency_bucket_versions',
  'SELECT * FROM store.latency_meter_days',
  'SELECT * FROM store.latency_endpoint_days',
  $q$SELECT admin.load_latency_buckets('{"version": 99, "bounds_ms": [1]}')$q$,
  'SELECT * FROM registry.meter_versions',
  'SELECT * FROM registry.meter_history',
  'SELECT * FROM registry.targets',
  'SELECT * FROM registry.target_versions',
  'SELECT * FROM registry.target_history',
  'SELECT * FROM registry.health_thresholds',
  $q$SELECT api.ingest('{}')$q$,
  $q$SELECT admin.set_health_thresholds('1 hour', 4, 0.8, '1 day', 0.05)$q$,
  $q$SELECT admin.retire_meter('SQLREG-0001', now())$q$,
  $q$SELECT admin.register_target('e', 1, now(), 'elite_440', NULL)$q$,
  $q$SELECT admin.retire_target('e', 1, now())$q$,
  $q$INSERT INTO registry.health_thresholds (collector_silent_after, meter_silent_intervals, backlog_near_capacity, lookback, endpoint_error_rate) VALUES ('1 hour', 4, 0.8, '1 day', 0.05)$q$,
  'SELECT * FROM store.profile_versions',
  'SELECT * FROM store.profile_registers',
  $q$INSERT INTO store.profile_versions (profile, version) VALUES ('elite_440', 99)$q$,
  $q$SELECT admin.load_profile('{"profile": "elite_440", "version": 99, "registers": []}')$q$,
  $q$DELETE FROM store.readings$q$,
  'CREATE TABLE health.x (i int)',
  'CREATE TEMP TABLE x (i int)'
]) q;

-- The role minkanakku_staff, and any login that is a member of it: it may
-- call jobs.request_job and read jobs.request_status, and nothing else. No
-- other role (the portal's, whatever it is named) may call jobs.request_job.
CREATE ROLE sqltest_staff_login IN ROLE minkanakku_staff;
CREATE ROLE sqltest_portal;

CREATE TEMP VIEW staff_roles AS
  SELECT r.rolname AS role FROM pg_roles r
  WHERE pg_has_role(r.oid, 'minkanakku_staff', 'USAGE') AND NOT r.rolsuper;

SELECT pg_temp.ok(
  (SELECT 'sqltest_staff_login' IN (SELECT role FROM staff_roles)),
  'a login that is a member of minkanakku_staff is among the roles checked');

SELECT pg_temp.is(
  (SELECT string_agg(r.rolname, ', ' ORDER BY r.rolname)
   FROM pg_roles r
   WHERE NOT r.rolsuper
     AND has_function_privilege(r.oid, 'jobs.request_job(text, text, text[], text)', 'EXECUTE')),
  (SELECT string_agg(role, ', ' ORDER BY role) FROM staff_roles),
  'no role but minkanakku_staff and its members may call jobs.request_job');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s may execute %s', r.role, f.oid::regprocedure), '; '
                     ORDER BY r.role, f.oid::regprocedure::text)
   FROM staff_roles r
   CROSS JOIN pg_proc f
   JOIN pg_namespace n ON n.oid = f.pronamespace
   WHERE n.nspname IN ('store', 'api', 'admin', 'registry', 'health', 'jobs')
     AND has_function_privilege(r.role, f.oid, 'EXECUTE')),
  (SELECT string_agg(format('%s may execute jobs.request_job(text,text,text[],text)', role), '; '
                     ORDER BY role)
   FROM staff_roles),
  'the only function minkanakku_staff may execute is jobs.request_job');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s has %s on %s.%s', r.role, p, c.nspname, c.relname), '; '
                     ORDER BY r.role, c.nspname, c.relname, p)
   FROM staff_roles r
   CROSS JOIN user_relations c
   CROSS JOIN unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'REFERENCES', 'DELETE', 'TRUNCATE',
                           'TRIGGER']) p
   WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
     AND CASE WHEN p IN ('SELECT', 'INSERT', 'UPDATE', 'REFERENCES')
              THEN has_any_column_privilege(r.role, c.oid, p)
              ELSE has_table_privilege(r.role, c.oid, p) END),
  (SELECT string_agg(format('%s has SELECT on jobs.request_status', role), '; ' ORDER BY role)
   FROM staff_roles),
  'minkanakku_staff may select from jobs.request_status and do nothing else to any table or view, chunks included');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s has %s on %s.%s', r.role, p, c.nspname, c.relname), '; ')
   FROM staff_roles r
   CROSS JOIN user_relations c
   CROSS JOIN unnest(ARRAY['USAGE', 'SELECT', 'UPDATE']) p
   WHERE c.relkind = 'S' AND has_sequence_privilege(r.role, c.oid, p)),
  NULL,
  'minkanakku_staff may use no sequence');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s has %s on schema %s', r.role, p, s.nspname), '; '
                     ORDER BY r.role, s.nspname, p)
   FROM staff_roles r
   CROSS JOIN user_schemas s
   CROSS JOIN unnest(ARRAY['USAGE', 'CREATE']) p
   WHERE has_schema_privilege(r.role, s.oid, p)),
  (SELECT string_agg(format('%s has USAGE on schema jobs', role), '; ' ORDER BY role)
   FROM staff_roles),
  'minkanakku_staff may use only the jobs schema, and create nothing in it');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s has %s', r.role, p), '; ')
   FROM staff_roles r
   CROSS JOIN unnest(ARRAY['CREATE', 'TEMPORARY']) p
   WHERE has_database_privilege(r.role, current_database(), p)),
  NULL,
  'minkanakku_staff may not create schemas or temporary tables');

SELECT pg_temp.is(
  (SELECT string_agg(m.roleid::regrole::text, '; ')
   FROM pg_auth_members m WHERE m.member = 'minkanakku_staff'::regrole),
  NULL,
  'minkanakku_staff is a member of no other role');

SELECT pg_temp.is(
  (SELECT string_agg(r.rolname, '; ')
   FROM pg_roles r
   WHERE r.rolname IN (SELECT role FROM staff_roles)
     AND (r.rolsuper OR r.rolcreaterole OR r.rolcreatedb OR r.rolbypassrls OR r.rolreplication
          OR (r.rolname = 'minkanakku_staff' AND r.rolcanlogin))),
  NULL,
  'minkanakku_staff cannot log in, and neither it nor its members hold a special attribute');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s may execute %s', r.role, f.oid::regprocedure), '; ')
   FROM (SELECT role FROM postgrest_roles UNION SELECT role FROM monitor_roles) r
   CROSS JOIN pg_proc f
   WHERE f.pronamespace = 'jobs'::regnamespace
     AND has_function_privilege(r.role, f.oid, 'EXECUTE')),
  NULL,
  'no PostgREST role and no monitor may execute any function in jobs');

-- The same, by trying. A call that gets past the privilege check is refused
-- for its arguments (22023), not for lack of privilege (42501).
SELECT pg_temp.is(pg_temp.sqlstate_as(r, q), '22023', r || ' may call: ' || q)
FROM unnest(ARRAY['minkanakku_staff', 'sqltest_staff_login']) r
CROSS JOIN unnest(ARRAY[
  $q$SELECT jobs.request_job('sqltest_none', 'read_on_demand', ARRAY['S'], 'staff:1')$q$
]) q;

SELECT pg_temp.is(pg_temp.sqlstate_as('minkanakku_staff', q), '00000',
                  'minkanakku_staff may: ' || q)
FROM unnest(ARRAY['SELECT * FROM jobs.request_status']) q;

SELECT pg_temp.is(pg_temp.sqlstate_as(r, q), '42501', r || ' is refused: ' || q)
FROM unnest(ARRAY['sqltest_portal', 'monitor', 'collector_sqltest_grants', 'authenticator']) r
CROSS JOIN unnest(ARRAY[
  $q$SELECT jobs.request_job('sqltest_grants', 'read_on_demand', ARRAY['S'], 'staff:1')$q$,
  'SELECT * FROM jobs.request_status',
  'SELECT * FROM jobs.requests'
]) q;

SELECT pg_temp.is(pg_temp.sqlstate_as('minkanakku_staff', q), '42501',
                  'minkanakku_staff is refused: ' || q)
FROM unnest(ARRAY[
  'SELECT * FROM jobs.requests',
  'SELECT * FROM jobs.request_readings',
  $q$INSERT INTO jobs.requests (collector_id, kind, requester, expires_at) VALUES ('sqltest_grants', 'read_on_demand', 'x', now() + interval '1 hour')$q$,
  $q$INSERT INTO jobs.request_meters VALUES (gen_random_uuid(), 'S')$q$,
  $q$UPDATE jobs.requests SET requester = 'x'$q$,
  $q$DELETE FROM jobs.requests$q$,
  $q$SELECT jobs.pending('sqltest_grants')$q$,
  $q$SELECT jobs.link_batch('{}', 'sqltest_grants', gen_random_uuid())$q$,
  'SELECT * FROM store.readings',
  'SELECT * FROM store.batches',
  'SELECT * FROM registry.meter_history',
  'SELECT * FROM registry.target_history',
  'SELECT * FROM health.problems',
  'SELECT * FROM health.targets',
  'SELECT * FROM health.collector_clocks',
  'SELECT * FROM health.energy_drops',
  'SELECT * FROM health.endpoints',
  'SELECT * FROM health.endpoint_latency',
  'SELECT * FROM store.latency_days',
  'SELECT * FROM store.latency_endpoint_days',
  'SELECT * FROM store.clock_checks',
  'SELECT * FROM store.clock_offsets',
  'SELECT * FROM store.ungrounded_readings',
  'SELECT * FROM store.energy_drops',
  $q$INSERT INTO store.readings VALUES ('S', 'r', now(), 1, 'p', 'h', 1, 1, 'c', gen_random_uuid(), 'P', 1)$q$,
  'SELECT * FROM store.profile_versions',
  'SELECT * FROM store.profile_registers',
  $q$INSERT INTO store.profile_versions (profile, version) VALUES ('elite_440', 99)$q$,
  $q$SELECT admin.load_profile('{"profile": "elite_440", "version": 99, "registers": []}')$q$,
  $q$SELECT api.ingest('{}')$q$,
  $q$SELECT admin.create_collector('sqltest_intruder')$q$,
  $q$SELECT admin.register_meter('S', now(), 'e', 1)$q$,
  $q$SELECT admin.register_target('e', 1, now(), 'elite_440', NULL)$q$,
  'CREATE TABLE jobs.x (i int)',
  'CREATE TEMP TABLE x (i int)'
]) q;

ROLLBACK;
