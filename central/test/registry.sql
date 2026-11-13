-- The device registry: changes add effective-dated rows and never lose
-- history; the history stays consistent, back-dated changes included.

\ir lib/assert.sql

BEGIN;

SELECT admin.create_collector('sqltest_reg_a');
SELECT admin.create_collector('sqltest_reg_b');

-- An endpoint with the polling settings of the collector's example config.
CREATE FUNCTION pg_temp.endpoint(id text, valid_from timestamptz, collector text, host text)
RETURNS bigint
LANGUAGE sql AS $$
  SELECT admin.register_endpoint(
    endpoint_id => id, valid_from => valid_from, collector_id => collector, host => host,
    port => 502, framing => 'tcp', polled_by_other_system => false, timeout_ms => 1000,
    max_timeouts => 3, retries => 2, busy_backoff_ms => 500, reconnect_backoff_min_ms => 1000,
    reconnect_backoff_max_ms => 60000, interval_ms => 900000)
$$;

-- A meter's history, one period per line.
CREATE FUNCTION pg_temp.meter_history(s text) RETURNS text
LANGUAGE sql AS $$
  SELECT string_agg(format('[%s, %s) %s %s/%s %s %s', valid_from, coalesce(valid_to::text, 'open'),
                           CASE WHEN in_service THEN 'in' ELSE 'retired' END, endpoint_id,
                           unit_id, profile, coalesce(interval_ms::text, 'endpoint')),
                    E'\n' ORDER BY valid_from)
  FROM registry.meter_history WHERE serial = s
$$;

SELECT pg_temp.endpoint('sqltest_ep_1', '2026-01-01Z', 'sqltest_reg_a', '10.0.0.21');
SELECT pg_temp.endpoint('sqltest_ep_2', '2026-01-01Z', 'sqltest_reg_a', '10.0.0.22');

SELECT admin.register_meter(serial => 'SQLREG-0001', valid_from => '2026-01-01Z',
  endpoint_id => 'sqltest_ep_1', unit_id => 1, profile => 'elite_440', interval_ms => NULL);
SELECT admin.change_meter(serial => 'SQLREG-0001', valid_from => '2026-02-01Z',
  endpoint_id => 'sqltest_ep_1', unit_id => 1, profile => 'elite_440', interval_ms => 60000);
SELECT admin.change_meter(serial => 'SQLREG-0001', valid_from => '2026-03-01Z',
  endpoint_id => 'sqltest_ep_2', unit_id => 5, profile => 'elite_440', interval_ms => 60000);
SELECT admin.retire_meter(serial => 'SQLREG-0001', valid_from => '2026-04-01Z');

SELECT pg_temp.is(pg_temp.meter_history('SQLREG-0001'),
  '[2026-01-01 00:00:00+00, 2026-02-01 00:00:00+00) in sqltest_ep_1/1 elite_440 endpoint' || E'\n'
  || '[2026-02-01 00:00:00+00, 2026-03-01 00:00:00+00) in sqltest_ep_1/1 elite_440 60000' || E'\n'
  || '[2026-03-01 00:00:00+00, 2026-04-01 00:00:00+00) in sqltest_ep_2/5 elite_440 60000' || E'\n'
  || '[2026-04-01 00:00:00+00, open) retired sqltest_ep_2/5 elite_440 60000',
  'an interval change, a move and a retirement each add a period; the earlier ones stay');

SELECT pg_temp.is(
  (SELECT count(*) FROM registry.meter_versions WHERE serial = 'SQLREG-0001'),
  4::bigint,
  'each change is a row of its own');

SELECT admin.change_meter(serial => 'SQLREG-0001', valid_from => '2026-03-01Z',
  endpoint_id => 'sqltest_ep_2', unit_id => 6, profile => 'elite_440', interval_ms => 60000);

SELECT pg_temp.is(
  (SELECT format('%s %s', unit_id, valid_to) FROM registry.meter_history
   WHERE serial = 'SQLREG-0001' AND valid_from = '2026-03-01Z'),
  '6 2026-04-01 00:00:00+00',
  'a correction at the same valid_from holds in place of the mistaken row');

SELECT pg_temp.is(
  (SELECT string_agg(unit_id::text, ' ' ORDER BY version_id) FROM registry.meter_versions
   WHERE serial = 'SQLREG-0001' AND valid_from = '2026-03-01Z'),
  '5 6',
  'the mistaken row is kept beside its correction');

SELECT admin.change_meter(serial => 'SQLREG-0001', valid_from => '2026-01-15Z',
  endpoint_id => 'sqltest_ep_1', unit_id => 1, profile => 'elite_440', interval_ms => 300000);

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s', valid_from::date, coalesce(interval_ms::text, 'endpoint')),
                     ', ' ORDER BY valid_from)
   FROM registry.meter_history WHERE serial = 'SQLREG-0001' AND valid_from < '2026-03-01Z'),
  '2026-01-01 endpoint, 2026-01-15 300000, 2026-02-01 60000',
  'a back-dated change holds only until the change after it');

SELECT admin.change_endpoint(
  endpoint_id => 'sqltest_ep_2', valid_from => '2026-05-01Z', collector_id => 'sqltest_reg_b',
  host => '10.1.0.5', port => 502, framing => 'rtu_over_tcp', polled_by_other_system => false,
  timeout_ms => 1000, max_timeouts => NULL, retries => 2, busy_backoff_ms => 500,
  reconnect_backoff_min_ms => 1000, reconnect_backoff_max_ms => 60000, interval_ms => 900000);

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s %s:%s %s', valid_from::date, collector_id, host, port, framing),
                     ', ' ORDER BY valid_from)
   FROM registry.endpoint_history WHERE endpoint_id = 'sqltest_ep_2'),
  '2026-01-01 sqltest_reg_a 10.0.0.22:502 tcp, 2026-05-01 sqltest_reg_b 10.1.0.5:502 rtu_over_tcp',
  'an endpoint keeps its identity and history across a move to another collector');

SELECT admin.register_meter(serial => 'SQLREG-0002', valid_from => '2026-01-01Z',
  endpoint_id => 'sqltest_ep_1', unit_id => 2, profile => 'elite_440', interval_ms => NULL);
SELECT admin.swap_meter(old_serial => 'SQLREG-0002', new_serial => 'SQLREG-0003',
  swapped_at => '2026-06-01Z', profile => 'elite_500');

SELECT pg_temp.is(
  pg_temp.meter_history('SQLREG-0002') || E'\n' || pg_temp.meter_history('SQLREG-0003'),
  '[2026-01-01 00:00:00+00, 2026-06-01 00:00:00+00) in sqltest_ep_1/2 elite_440 endpoint' || E'\n'
  || '[2026-06-01 00:00:00+00, open) retired sqltest_ep_1/2 elite_440 endpoint' || E'\n'
  || '[2026-06-01 00:00:00+00, open) in sqltest_ep_1/2 elite_500 endpoint',
  'a swap retires the old meter and puts the new one in its place');

SELECT pg_temp.is(
  (SELECT format('%s %s %s', old_serial, new_serial, swapped_at) FROM registry.meter_swaps),
  'SQLREG-0002 SQLREG-0003 2026-06-01 00:00:00+00',
  'the swap is recorded');

SELECT pg_temp.is(pg_temp.sqlstate_as('postgres', q), '23P01', 'refused: ' || q)
FROM unnest(ARRAY[
  -- unit id 1 on sqltest_ep_1 is SQLREG-0001's until 2026-03-01
  $q$SELECT admin.register_meter(serial => 'SQLREG-0009', valid_from => '2026-02-15Z',
       endpoint_id => 'sqltest_ep_1', unit_id => 1, profile => 'elite_440', interval_ms => NULL)$q$,
  -- back-dated into a period in which SQLREG-0002 holds unit id 2
  $q$SELECT admin.change_meter(serial => 'SQLREG-0001', valid_from => '2026-02-15Z',
       endpoint_id => 'sqltest_ep_1', unit_id => 2, profile => 'elite_440', interval_ms => NULL)$q$,
  -- SQLREG-0003 is still in service there
  $q$SELECT admin.retire_endpoint(endpoint_id => 'sqltest_ep_1', valid_from => '2026-07-01Z')$q$,
  -- before the endpoint was registered
  $q$SELECT admin.register_meter(serial => 'SQLREG-0009', valid_from => '2025-01-01Z',
       endpoint_id => 'sqltest_ep_1', unit_id => 9, profile => 'elite_440', interval_ms => NULL)$q$,
  -- the same address on the same collector, at the same time
  $q$SELECT pg_temp.endpoint('sqltest_ep_3', '2026-02-01Z', 'sqltest_reg_a', '10.0.0.21')$q$
]) q;

SELECT pg_temp.ok(
  pg_temp.sqlstate_as('postgres',
    $q$SELECT pg_temp.endpoint('sqltest_ep_3', '2026-02-01Z', 'sqltest_reg_b', '10.0.0.21')$q$)
  = '00000',
  'the same address on another collector is another endpoint');

SELECT pg_temp.is(pg_temp.sqlstate_as('postgres', q), 'P0001', 'refused: ' || q)
FROM unnest(ARRAY[
  $q$SELECT admin.retire_meter(serial => 'SQLREG-0001', valid_from => '2026-12-01Z')$q$,
  $q$SELECT admin.change_meter(serial => 'SQLREG-NONE', valid_from => '2026-01-01Z',
       endpoint_id => 'sqltest_ep_1', unit_id => 9, profile => 'elite_440', interval_ms => NULL)$q$
]) q;

SELECT pg_temp.is(pg_temp.sqlstate_as('postgres', q), '23514', 'out of range: ' || q)
FROM unnest(ARRAY[
  $q$SELECT admin.register_meter(serial => 'SQLREG-0010', valid_from => '2026-01-01Z',
       endpoint_id => 'sqltest_ep_1', unit_id => 248, profile => 'elite_440', interval_ms => NULL)$q$,
  $q$SELECT admin.register_meter(serial => 'SQLREG-0010', valid_from => '2026-01-01Z',
       endpoint_id => 'sqltest_ep_1', unit_id => 10, profile => 'elite_440', interval_ms => 0)$q$,
  $q$SELECT admin.register_meter(serial => 'SQLREG-0010', valid_from => 'infinity',
       endpoint_id => 'sqltest_ep_1', unit_id => 10, profile => 'elite_440', interval_ms => NULL)$q$,
  -- max_timeouts is for Modbus TCP only
  $q$SELECT admin.change_endpoint(
       endpoint_id => 'sqltest_ep_2', valid_from => '2026-07-01Z', collector_id => 'sqltest_reg_b',
       host => '10.1.0.5', port => 502, framing => 'rtu_over_tcp', polled_by_other_system => false,
       timeout_ms => 1000, max_timeouts => 3, retries => 2, busy_backoff_ms => 500,
       reconnect_backoff_min_ms => 1000, reconnect_backoff_max_ms => 60000, interval_ms => 900000)$q$
]) q;

SELECT pg_temp.is(pg_temp.sqlstate_as('postgres', q), 'P0001', 'the owner is refused: ' || q)
FROM unnest(ARRAY[
  'UPDATE registry.meter_versions SET unit_id = 7',
  'DELETE FROM registry.meter_versions',
  'TRUNCATE registry.meter_versions',
  'UPDATE registry.endpoint_versions SET host = $$x$$',
  'DELETE FROM registry.endpoint_versions',
  'DELETE FROM registry.meters',
  'DELETE FROM registry.endpoints',
  'DELETE FROM registry.meter_swaps'
]) q;

ROLLBACK;
