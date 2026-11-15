-- The registry's checks against contract/config: every integer the schema
-- bounds is refused just outside its range and accepted at each end, the
-- framings are the schema's, and the fixture's cases for a value the registry
-- stores get the verdict the schema and the collector give them.

\ir lib/assert.sql
\set schema `cat ../contract/config/config.v1.schema.json`
\set basic `cat ../contract/fixtures/config.v1.basic.json`
\set cases `cat ../contract/fixtures/config.v1.cases.json`

BEGIN;

SELECT admin.create_collector('sqltest_cfg');

-- Register the config's first endpoint and its first meter, as the polling
-- config would be held here, and undo it; the SQLSTATE, '00000' if it held.
CREATE FUNCTION pg_temp.register(config jsonb) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
  e jsonb := config #> '{endpoints,0}';
  m jsonb := config #> '{endpoints,0,meters,0}';
BEGIN
  PERFORM admin.register_endpoint(
    endpoint_id => 'sqltest_cfg_ep', valid_from => '2026-01-01Z', collector_id => 'sqltest_cfg',
    host => e ->> 'host', port => (e ->> 'port')::integer,
    framing => (e ->> 'framing')::registry.framing,
    polled_by_other_system => (e ->> 'polled_by_other_system')::boolean,
    timeout_ms => (e ->> 'timeout_ms')::integer, max_timeouts => (e ->> 'max_timeouts')::integer,
    retries => (e ->> 'retries')::integer, busy_backoff_ms => (e ->> 'busy_backoff_ms')::integer,
    reconnect_backoff_min_ms => (e #>> '{reconnect_backoff_ms,min}')::integer,
    reconnect_backoff_max_ms => (e #>> '{reconnect_backoff_ms,max}')::integer,
    interval_ms => (e ->> 'interval_ms')::integer);
  PERFORM admin.register_meter(
    serial => m ->> 'serial', valid_from => '2026-01-01Z', endpoint_id => 'sqltest_cfg_ep',
    unit_id => (m ->> 'unit_id')::integer, profile => m ->> 'profile',
    interval_ms => (m ->> 'interval_ms')::integer);
  RAISE SQLSTATE 'TT000';
EXCEPTION
  WHEN SQLSTATE 'TT000' THEN
    RETURN '00000';
  WHEN OTHERS THEN
    RETURN SQLSTATE;
END
$$;

-- A valid entry's changes, in order.
CREATE FUNCTION pg_temp.applied(config jsonb, changes jsonb) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  c jsonb;
BEGIN
  FOR c IN SELECT jsonb_array_elements(changes) LOOP
    config := pg_temp.changed(config, c);
  END LOOP;
  RETURN config;
END
$$;

-- A schema node with its $ref (to #/$defs/...) resolved.
CREATE FUNCTION pg_temp.resolved(schema jsonb, node jsonb) RETURNS jsonb
LANGUAGE sql AS $$
  SELECT CASE WHEN node ? '$ref'
              THEN (schema #> string_to_array(substr(node ->> '$ref', 3), '/')) || (node - '$ref')
              ELSE node END
$$;

-- Every bounded integer in the schema, at its path in the config's first
-- endpoint and first meter: {endpoints,0,port}, {endpoints,0,meters,0,unit_id}.
CREATE TEMP TABLE bounded AS
WITH RECURSIVE walk(path, node) AS (
  SELECT ARRAY[]::text[], pg_temp.resolved(:'schema', :'schema')
  UNION ALL
  SELECT w.path || k.next, pg_temp.resolved(:'schema', k.node)
  FROM walk w
  CROSS JOIN LATERAL (
    SELECT p.key AS next, p.value AS node FROM jsonb_each(w.node -> 'properties') p
    UNION ALL
    SELECT '0', w.node -> 'items' WHERE w.node ? 'items'
  ) k
)
SELECT path, (node ->> 'minimum')::bigint AS minimum, (node ->> 'maximum')::bigint AS maximum
FROM walk WHERE node ->> 'type' = 'integer';

SELECT pg_temp.is(
  (SELECT string_agg(array_to_string(path, '.'), ' ' ORDER BY path) FROM bounded),
  'endpoints.0.busy_backoff_ms endpoints.0.interval_ms endpoints.0.max_timeouts '
  || 'endpoints.0.meters.0.interval_ms endpoints.0.meters.0.unit_id endpoints.0.port '
  || 'endpoints.0.reconnect_backoff_ms.max endpoints.0.reconnect_backoff_ms.min '
  || 'endpoints.0.retries endpoints.0.timeout_ms',
  'the schema bounds the integers the registry stores, and only those');

SELECT pg_temp.is(pg_temp.register(:'basic'), '00000', 'the registry holds the contract fixture');

-- A backoff's max is no less than its min, so a value for either is given to both.
CREATE FUNCTION pg_temp.with_value(config jsonb, path text[], v bigint) RETURNS jsonb
LANGUAGE sql AS $$
  SELECT CASE WHEN path[3] = 'reconnect_backoff_ms'
              THEN jsonb_set(config, path[1:3], jsonb_build_object('min', v, 'max', v))
              ELSE jsonb_set(config, path, to_jsonb(v)) END
$$;

SELECT pg_temp.is(pg_temp.register(pg_temp.with_value(:'basic', path, v)), want,
  format('the registry %s %s = %s, as the schema does',
         CASE want WHEN '00000' THEN 'accepts' ELSE 'refuses' END, array_to_string(path, '.'), v))
FROM bounded
CROSS JOIN LATERAL (VALUES (minimum, '00000'), (maximum, '00000'),
                           (minimum - 1, '23514'), (maximum + 1, '23514')) t(v, want);

SELECT pg_temp.is(
  (SELECT jsonb_agg(f::text ORDER BY f::text) FROM unnest(enum_range(NULL::registry.framing)) f),
  (SELECT jsonb_agg(f ORDER BY f::text)
   FROM jsonb_array_elements(:'schema'::jsonb #> '{$defs,endpoint,properties,framing,enum}') f),
  'the registry''s framings are the schema''s');

SELECT pg_temp.ok(pg_temp.register(pg_temp.changed(:'basic', c)) <> '00000',
  'the registry refuses the contract''s case ' || (c ->> 'name'))
FROM jsonb_array_elements(:'cases'::jsonb -> 'cases') c
WHERE c -> 'by' ? 'registry';

SELECT pg_temp.is(pg_temp.register(pg_temp.applied(:'basic', v -> 'changes')), '00000',
  'the registry accepts the contract''s change ' || (v ->> 'name'))
FROM jsonb_array_elements(:'cases'::jsonb -> 'valid') v
WHERE v -> 'by' ? 'registry';

ROLLBACK;
