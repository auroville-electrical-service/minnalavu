-- The polling config served from the registry: api.collector_config gives
-- the calling collector its endpoints and targets in service now, as
-- contract/fixtures/config.v1.basic.json for a registry holding that
-- config; every ingest answer carries its digest, as
-- contract/fixtures/config.v1.digests.json computes it; and a collector's
-- report of a refused config is kept and raised as config_refused.

\ir lib/assert.sql
\set basic `cat ../contract/fixtures/config.v1.basic.json`
\set digests `cat ../contract/fixtures/config.v1.digests.json`
\set batch `cat ../contract/fixtures/batch.v1.basic.json`

BEGIN;

SELECT admin.set_health_thresholds(collector_silent_after => '1 hour',
  meter_silent_intervals => 4, backlog_near_capacity => 0.8, lookback => '1 day',
  endpoint_error_rate => 0.05);

SELECT admin.create_collector(c)
FROM unnest(ARRAY['sqltest_srv_a', 'sqltest_srv_b', 'sqltest_srv_c']) c;

-- Call api.collector_config as role, as PostgREST does after SET ROLE.
CREATE FUNCTION pg_temp.config_as(role text) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  config jsonb;
BEGIN
  EXECUTE format('SET LOCAL ROLE %I', role);
  config := api.collector_config();
  RESET ROLE;
  RETURN config;
END
$$;

-- A heartbeat from contract/fixtures/batch.v1.basic.json, with id and the
-- backlog's config (none when NULL).
CREATE FUNCTION pg_temp.heartbeat(batch jsonb, id uuid, config jsonb) RETURNS jsonb
LANGUAGE sql AS $$
  SELECT CASE WHEN config IS NULL THEN b ELSE jsonb_set(b, '{backlog,config}', config) END
  FROM (SELECT batch || jsonb_build_object('batch_id', id, 'readings', '[]'::jsonb,
                                           'missed_reads', '[]'::jsonb) AS b) x
$$;

-- An endpoint of a config, registered as id from valid_from.
CREATE FUNCTION pg_temp.endpoint(id text, collector text, e jsonb, valid_from timestamptz)
RETURNS bigint
LANGUAGE sql AS $$
  SELECT admin.register_endpoint(
    endpoint_id => id, valid_from => valid_from, collector_id => collector,
    host => e ->> 'host', port => (e ->> 'port')::integer,
    framing => (e ->> 'framing')::registry.framing,
    polled_by_other_system => (e ->> 'polled_by_other_system')::boolean,
    timeout_ms => (e ->> 'timeout_ms')::integer, max_timeouts => (e ->> 'max_timeouts')::integer,
    retries => (e ->> 'retries')::integer, busy_backoff_ms => (e ->> 'busy_backoff_ms')::integer,
    reconnect_backoff_min_ms => (e #>> '{reconnect_backoff_ms,min}')::integer,
    reconnect_backoff_max_ms => (e #>> '{reconnect_backoff_ms,max}')::integer,
    interval_ms => (e ->> 'interval_ms')::integer)
$$;

-- Each of a config's endpoints as sqltest_srv_<i>, with its meters as
-- targets and their serials as meters placed there, two days ago.
SELECT pg_temp.endpoint('sqltest_srv_' || i, 'sqltest_srv_a', e, now() - interval '2 days')
FROM jsonb_array_elements(:'basic'::jsonb -> 'endpoints') WITH ORDINALITY x(e, i);

SELECT admin.register_target(endpoint_id => 'sqltest_srv_' || i, unit_id => (m ->> 'unit_id')::integer,
  valid_from => now() - interval '2 days', profile => m ->> 'profile',
  interval_ms => (m ->> 'interval_ms')::integer)
FROM jsonb_array_elements(:'basic'::jsonb -> 'endpoints') WITH ORDINALITY x(e, i)
CROSS JOIN jsonb_array_elements(e -> 'meters') m;

SELECT admin.register_meter(serial => m ->> 'serial', valid_from => now() - interval '2 days',
  endpoint_id => 'sqltest_srv_' || i, unit_id => (m ->> 'unit_id')::integer)
FROM jsonb_array_elements(:'basic'::jsonb -> 'endpoints') WITH ORDINALITY x(e, i)
CROSS JOIN jsonb_array_elements(e -> 'meters') m
WHERE m ? 'serial';

-- What is not in service now: a target retired, a target from tomorrow, a
-- meter retired from a target that is still polled, an endpoint retired and
-- one from tomorrow; and an endpoint of another collector.
SELECT admin.register_target(endpoint_id => 'sqltest_srv_1', unit_id => 5,
  valid_from => now() - interval '2 days', profile => 'elite_440', interval_ms => NULL);
SELECT admin.retire_target(endpoint_id => 'sqltest_srv_1', unit_id => 5,
  valid_from => now() - interval '1 day');
SELECT admin.register_target(endpoint_id => 'sqltest_srv_1', unit_id => 6,
  valid_from => now() + interval '1 day', profile => 'elite_440', interval_ms => NULL);
SELECT admin.register_meter(serial => 'SQLSRV-GONE', valid_from => now() - interval '2 days',
  endpoint_id => 'sqltest_srv_1', unit_id => 3);
SELECT admin.retire_meter(serial => 'SQLSRV-GONE', valid_from => now() - interval '1 day');

SELECT pg_temp.endpoint('sqltest_srv_old', 'sqltest_srv_a',
  jsonb_set(:'basic'::jsonb #> '{endpoints,0}', '{host}', '"192.0.2.99"'),
  now() - interval '2 days');
SELECT admin.register_target(endpoint_id => 'sqltest_srv_old', unit_id => 1,
  valid_from => now() - interval '2 days', profile => 'elite_440', interval_ms => NULL);
SELECT admin.retire_target(endpoint_id => 'sqltest_srv_old', unit_id => 1,
  valid_from => now() - interval '1 day');
SELECT admin.retire_endpoint(endpoint_id => 'sqltest_srv_old', valid_from => now() - interval '1 day');

SELECT pg_temp.endpoint('sqltest_srv_new', 'sqltest_srv_a',
  jsonb_set(:'basic'::jsonb #> '{endpoints,0}', '{host}', '"192.0.2.98"'),
  now() + interval '1 day');
SELECT admin.register_target(endpoint_id => 'sqltest_srv_new', unit_id => 1,
  valid_from => now() + interval '1 day', profile => 'elite_440', interval_ms => NULL);

SELECT pg_temp.endpoint('sqltest_srv_b1', 'sqltest_srv_b',
  jsonb_set(:'basic'::jsonb #> '{endpoints,0}', '{host}', '"192.0.2.77"'),
  now() - interval '2 days');
SELECT admin.register_target(endpoint_id => 'sqltest_srv_b1', unit_id => 9,
  valid_from => now() - interval '2 days', profile => 'elite_500', interval_ms => NULL);

-- Serving

SELECT pg_temp.is(pg_temp.config_as('collector_sqltest_srv_a'), :'basic'::jsonb,
  'a collector is served the config the registry holds for it now: its endpoints and targets '
  || 'in service, the serial placed at each, an interval only where a target has its own, '
  || 'and an endpoint another system polls as it is');

SELECT pg_temp.is(
  pg_temp.config_as('collector_sqltest_srv_b') #>> '{endpoints,0,host}'
    || ' ' || jsonb_array_length(pg_temp.config_as('collector_sqltest_srv_b') -> 'endpoints'),
  '192.0.2.77 1',
  'another collector is served its own endpoints and only those');

SELECT pg_temp.endpoint('sqltest_srv_b' || i, 'sqltest_srv_b',
  :'basic'::jsonb #> '{endpoints,0}' || jsonb_build_object('host', host, 'port', port),
  now() - interval '1 day')
FROM (VALUES (2, 'ab.example.invalid', 502), (3, '192.0.2.77', 501),
             (4, 'a-z.example.invalid', 502)) v (i, host, port);

SELECT pg_temp.is(
  (SELECT string_agg(format('%s:%s', e ->> 'host', e ->> 'port'), ' ' ORDER BY i)
   FROM jsonb_array_elements(pg_temp.config_as('collector_sqltest_srv_b') -> 'endpoints')
        WITH ORDINALITY x(e, i)),
  '192.0.2.77:501 192.0.2.77:502 a-z.example.invalid:502 ab.example.invalid:502',
  'endpoints are served by host, by its bytes whatever the collation, then by port');

SELECT pg_temp.is(pg_temp.config_as('collector_sqltest_srv_c'),
  '{"schema_version": 1, "endpoints": []}'::jsonb,
  'a collector with no endpoint in service is served a config with none, for it to refuse');

SELECT pg_temp.endpoint('sqltest_srv_c1', 'sqltest_srv_c', :'basic'::jsonb #> '{endpoints,1}',
  now() - interval '1 day');
SELECT pg_temp.is(pg_temp.config_as('collector_sqltest_srv_c') #> '{endpoints,0,meters}',
  '[]'::jsonb,
  'an endpoint with no target in service is served with no meters, for the collector to refuse');

SELECT pg_temp.is(pg_temp.sqlstate_as('collector', 'SELECT api.collector_config()'), 'PT403',
  'a role that is not a registered collector is refused');

-- The digest

SELECT pg_temp.is(registry.canonical_json(pg_temp.applied(:'basic', c -> 'changes')),
  c ->> 'canonical', 'the canonical encoding of the contract''s case ' || (c ->> 'name'))
FROM jsonb_array_elements(:'digests'::jsonb -> 'cases') c;

SELECT pg_temp.is(registry.config_digest(pg_temp.applied(:'basic', c -> 'changes')),
  c ->> 'digest', 'the digest of the contract''s case ' || (c ->> 'name'))
FROM jsonb_array_elements(:'digests'::jsonb -> 'cases') c;

CREATE TEMP TABLE answers (name text PRIMARY KEY, answer jsonb);
INSERT INTO answers VALUES ('a', pg_temp.ingest_as('collector_sqltest_srv_a',
  pg_temp.heartbeat(:'batch', 'd0000000-0000-4000-8000-000000000001', NULL)));

SELECT pg_temp.is((SELECT answer ->> 'config_digest' FROM answers WHERE name = 'a'),
  (SELECT c ->> 'digest' FROM jsonb_array_elements(:'digests'::jsonb -> 'cases') c
   WHERE c ->> 'name' = 'the basic config'),
  'a heartbeat''s answer carries the digest of the config the collector is served');

SELECT pg_temp.is(
  pg_temp.ingest_as('collector_sqltest_srv_b',
    pg_temp.heartbeat(:'batch', 'd0000000-0000-4000-8000-000000000002', NULL)) ->> 'config_digest',
  registry.config_digest(pg_temp.config_as('collector_sqltest_srv_b')),
  'each collector''s answer carries the digest of its own config');

SELECT admin.change_target(endpoint_id => 'sqltest_srv_1', unit_id => 1, valid_from => now(),
  profile => 'elite_440', interval_ms => 120000);

SELECT pg_temp.ok(
  pg_temp.ingest_as('collector_sqltest_srv_a',
    pg_temp.heartbeat(:'batch', 'd0000000-0000-4000-8000-000000000003', NULL)) ->> 'config_digest'
  IS DISTINCT FROM (SELECT answer ->> 'config_digest' FROM answers WHERE name = 'a'),
  'a change in the registry changes the digest in the next answer');

-- The backlog's config, and config_refused

\set applied '"89b20b78a45d85313e9e7ef0fe3772808a642480722d0e36f04e6b8d58ed2333"'
\set refused '"9ac24ff085fb90434c2ce98647cce379a3de2df6d941206cead503702fa1d0d0"'

SELECT pg_temp.ingest_as('collector_sqltest_srv_a',
  pg_temp.heartbeat(:'batch', 'd0000000-0000-4000-8000-000000000004',
    jsonb_build_object('digest', :'applied'::jsonb, 'refused_digest', :'refused'::jsonb,
                       'reason', E'endpoints: must have\nat least 1 item')));

SELECT pg_temp.is(
  (SELECT format('%s %s %s', config_digest, config_refused_digest, config_refusal_reason)
   FROM store.uploads WHERE batch_id = 'd0000000-0000-4000-8000-000000000004'),
  format('%s %s %s', :'applied'::jsonb #>> '{}', :'refused'::jsonb #>> '{}',
         E'endpoints: must have\nat least 1 item'),
  'the upload keeps the backlog''s config as the collector reported it');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s: %s', kind, subject, detail), '; ')
   FROM health.problems WHERE kind = 'config_refused'),
  format('config_refused sqltest_srv_a: refused the served config %s '
         || '(endpoints: must have?at least 1 item); still applying %s',
         :'refused'::jsonb #>> '{}', :'applied'::jsonb #>> '{}'),
  'a collector whose latest upload reports a refused config raises config_refused, '
  || 'with the digests and the reason, control characters shown as ?');

SELECT pg_temp.ingest_as('collector_sqltest_srv_c',
  pg_temp.heartbeat(:'batch', 'd0000000-0000-4000-8000-000000000005',
    jsonb_build_object('digest', :'applied'::jsonb, 'refused_digest', :'refused'::jsonb,
                       'reason', 'endpoints[0].meters: must have at least 1 item')));
SELECT admin.retire_endpoint(endpoint_id => 'sqltest_srv_c1', valid_from => now());

SELECT pg_temp.is(
  (SELECT string_agg(subject, ', ') FROM health.problems WHERE kind = 'config_refused'),
  'sqltest_srv_a',
  'a collector with no endpoint in service raises no config_refused');

SELECT pg_temp.ingest_as('collector_sqltest_srv_a',
  pg_temp.heartbeat(:'batch', 'd0000000-0000-4000-8000-000000000006',
    jsonb_build_object('digest', :'applied'::jsonb, 'refused_digest', NULL, 'reason', NULL)));

SELECT pg_temp.is(
  (SELECT count(*) FROM health.problems WHERE kind = 'config_refused'), 0::bigint,
  'config_refused clears when the latest upload reports no refused config');

SELECT pg_temp.ingest_as('collector_sqltest_srv_a',
  pg_temp.heartbeat(:'batch', 'd0000000-0000-4000-8000-000000000008',
    jsonb_build_object('digest', :'applied'::jsonb, 'refused_digest', :'refused'::jsonb,
                       'reason', 'x')));
SELECT pg_temp.ingest_as('collector_sqltest_srv_a',
  pg_temp.heartbeat(:'batch', 'd0000000-0000-4000-8000-000000000007', NULL));

SELECT pg_temp.is(
  (SELECT count(*) FROM health.problems WHERE kind = 'config_refused'), 0::bigint,
  'nor is it raised when the latest upload reports no config at all');

ROLLBACK;
