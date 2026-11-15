-- Reads on demand: what jobs.request_job accepts and records, how ingest
-- offers a collector its own pending jobs and links what comes back, what a
-- request's state is, and the notice ingest sends when it commits. Who may call
-- what is in grants.sql.
--
-- The notice goes out only on commit, so the last part of this file commits
-- on two connections of its own (dblink) in the test database, which bin/test
-- drops on every run; everything before it is rolled back.

\ir lib/assert.sql
\set basic `cat ../contract/fixtures/batch.v1.basic.json`

CREATE FUNCTION pg_temp.endpoint(id text, collector text, host text, other boolean)
RETURNS bigint
LANGUAGE sql AS $$
  SELECT admin.register_endpoint(
    endpoint_id => id, valid_from => '2026-01-01Z', collector_id => collector, host => host,
    port => 502, framing => 'tcp', polled_by_other_system => other, timeout_ms => 1000,
    max_timeouts => 3, retries => 2, busy_backoff_ms => 500, reconnect_backoff_min_ms => 1000,
    reconnect_backoff_max_ms => 60000, interval_ms => 900000)
$$;

CREATE FUNCTION pg_temp.meter(serial text, valid_from timestamptz, endpoint text, unit integer)
RETURNS bigint
LANGUAGE sql AS $$
  SELECT admin.register_meter(serial => serial, valid_from => valid_from,
    endpoint_id => endpoint, unit_id => unit, profile => 'elite_440', interval_ms => NULL)
$$;

-- Call jobs.request_job as role, as minkanakku does.
CREATE FUNCTION pg_temp.request_as(role text, collector text, kind text, meters text[],
                                   requester text)
RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  id uuid;
BEGIN
  EXECUTE format('SET LOCAL ROLE %I', role);
  id := jobs.request_job(collector_id => collector, kind => kind, meters => meters,
                         requester => requester);
  RESET ROLE;
  RETURN id;
END
$$;

-- The error jobs.request_job raises, as 'SQLSTATE: message', or 'ok'.
CREATE FUNCTION pg_temp.request_error(collector text, kind text, meters text[], requester text)
RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_temp.request_as('minkanakku_staff', collector, kind, meters, requester);
  RETURN 'ok';
EXCEPTION
  WHEN OTHERS THEN
    RETURN SQLSTATE || ': ' || SQLERRM;
END
$$;

-- Rows per table in store, registry and jobs, hypertables' chunks included.
CREATE FUNCTION pg_temp.row_counts() RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  t regclass;
  counts jsonb := '{}';
BEGIN
  FOR t IN
    SELECT c.oid FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname IN ('store', 'registry', 'jobs') AND c.relkind IN ('r', 'p')
  LOOP
    EXECUTE format('SELECT $1 || jsonb_build_object(%L, count(*)) FROM %s', t, t)
      INTO counts USING counts;
  END LOOP;
  RETURN counts;
END
$$;

-- The tables whose row counts differ, and by how much.
CREATE FUNCTION pg_temp.count_changes(before jsonb, after jsonb) RETURNS text
LANGUAGE sql AS $$
  SELECT string_agg(format('%s %s', k, (after ->> k)::bigint - (before ->> k)::bigint), ', '
                    ORDER BY k)
  FROM jsonb_object_keys(after) k WHERE after -> k IS DISTINCT FROM before -> k
$$;

-- A batch from the basic fixture with this id, readings and missed reads.
CREATE FUNCTION pg_temp.batch(basic jsonb, id text, readings jsonb, missed jsonb) RETURNS jsonb
LANGUAGE sql AS $$
  SELECT jsonb_set(jsonb_set(jsonb_set(basic, '{batch_id}', to_jsonb(id)),
                             '{readings}', readings), '{missed_reads}', missed)
$$;

CREATE FUNCTION pg_temp.reading(serial text, unit integer, at text, request uuid, value text)
RETURNS jsonb
LANGUAGE sql AS $$
  SELECT jsonb_strip_nulls(jsonb_build_object(
    'endpoint', jsonb_build_object('host', '10.0.0.41', 'port', 502), 'unit_id', unit,
    'meter_serial', serial, 'product_code', 'ELITE440-445', 'profile', 'elite_440',
    'profile_version', 1, 'register_key', 'active_energy_import', 'timestamp', at,
    'value', value, 'request_id', request))
$$;

CREATE FUNCTION pg_temp.missed(serial text, unit integer, at text, request uuid) RETURNS jsonb
LANGUAGE sql AS $$
  SELECT jsonb_strip_nulls(jsonb_build_object(
    'endpoint', jsonb_build_object('host', '10.0.0.41', 'port', 502), 'unit_id', unit,
    'meter_serial', serial, 'profile', 'elite_440', 'profile_version', 1,
    'register_key', 'active_energy_import',
    'timestamp', at, 'reason', 'timeout', 'exception_code', NULL, 'detail', NULL,
    'attempts', 3, 'raw_words', NULL, 'request_id', request))
  || '{"exception_code": null, "detail": null, "raw_words": null}'
$$;

-- The job the ingest answer lists for a request.
CREATE FUNCTION pg_temp.job(id uuid) RETURNS jsonb
LANGUAGE sql AS $$
  SELECT jsonb_build_object('request_id', s.request_id, 'kind', s.kind, 'meters', to_jsonb(s.meters),
                            'requested_at', s.requested_at, 'expires_at', s.expires_at)
  FROM jobs.request_status s WHERE s.request_id = id
$$;

BEGIN;

SELECT admin.create_collector('sqltest_req_a');
SELECT admin.create_collector('sqltest_req_b');

SELECT pg_temp.endpoint('sqltest_req_ep_a', 'sqltest_req_a', '10.0.0.41', false);
SELECT pg_temp.endpoint('sqltest_req_ep_b', 'sqltest_req_b', '10.0.0.42', false);
SELECT pg_temp.endpoint('sqltest_req_ep_o', 'sqltest_req_a', '10.0.0.43', true);
SELECT pg_temp.meter('SQLREQ-A1', '2026-01-01Z', 'sqltest_req_ep_a', 1);
SELECT pg_temp.meter('SQLREQ-A2', '2026-01-01Z', 'sqltest_req_ep_a', 2);
SELECT pg_temp.meter('SQLREQ-A3', '2026-01-01Z', 'sqltest_req_ep_a', 3);
SELECT admin.retire_meter(serial => 'SQLREQ-A3', valid_from => '2026-02-01Z');
SELECT pg_temp.meter('SQLREQ-A4', now() + interval '1 day', 'sqltest_req_ep_a', 4);
SELECT pg_temp.meter('SQLREQ-B1', '2026-01-01Z', 'sqltest_req_ep_b', 1);
SELECT pg_temp.meter('SQLREQ-O1', '2026-01-01Z', 'sqltest_req_ep_o', 1);
SELECT pg_temp.meter('SQLREQ-M1', '2026-01-01Z', 'sqltest_req_ep_b', 2);
SELECT admin.change_meter(serial => 'SQLREQ-M1', valid_from => '2026-03-01Z',
  endpoint_id => 'sqltest_req_ep_a', unit_id => 5, profile => 'elite_440', interval_ms => NULL);

CREATE TEMP TABLE ids (name text PRIMARY KEY, id uuid);
CREATE TEMP TABLE snapshots (name text PRIMARY KEY, counts jsonb);
CREATE TEMP TABLE answers (name text PRIMARY KEY, answer jsonb);


-- jobs.request_job

INSERT INTO snapshots VALUES ('before', pg_temp.row_counts());
INSERT INTO ids VALUES ('a', pg_temp.request_as('minkanakku_staff', 'sqltest_req_a',
  'read_on_demand', ARRAY['SQLREQ-A2', 'SQLREQ-A1'], 'staff:42'));
INSERT INTO snapshots VALUES ('after', pg_temp.row_counts());

SELECT pg_temp.is(
  (SELECT format('%s %s %s %s %s %s %s %s %s %s', s.collector_id, s.kind, s.meters, s.requester,
                 s.requested_at = now(), s.expires_at = now() + interval '1 hour', s.state,
                 s.readings, s.missed_reads, coalesce(s.answered_at::text, 'unanswered'))
   FROM jobs.request_status s WHERE s.request_id = (SELECT id FROM ids WHERE name = 'a')),
  'sqltest_req_a read_on_demand {SQLREQ-A1,SQLREQ-A2} staff:42 t t pending 0 0 unanswered',
  'a request records the collector, kind, meters and requester, now, and expires in an hour');

SELECT pg_temp.is(
  pg_temp.count_changes((SELECT counts FROM snapshots WHERE name = 'before'),
                        (SELECT counts FROM snapshots WHERE name = 'after')),
  'jobs.request_meters 2, jobs.requests 1',
  'a request adds its row and its meters, and touches nothing else');

SELECT pg_temp.ok(
  pg_temp.request_error('sqltest_req_a', 'read_on_demand', ARRAY['SQLREQ-M1'], 'staff:42') = 'ok',
  'a meter moved to the collector may be requested from it');

SELECT pg_temp.is(pg_temp.request_error(c.collector, c.kind, c.meters, c.requester), c.error,
                  'a request is refused: ' || c.name)
FROM (VALUES
  ('another kind', 'sqltest_req_a', 'copy_billing_history', ARRAY['SQLREQ-A1'], 'staff:42',
   '22023: kind copy_billing_history cannot be requested: only read_on_demand can'),
  ('no kind', 'sqltest_req_a', NULL, ARRAY['SQLREQ-A1'], 'staff:42',
   '22023: kind (none) cannot be requested: only read_on_demand can'),
  ('an unregistered collector', 'sqltest_req_none', 'read_on_demand', ARRAY['SQLREQ-A1'],
   'staff:42', '22023: collector sqltest_req_none is not registered'),
  ('no requester', 'sqltest_req_a', 'read_on_demand', ARRAY['SQLREQ-A1'], NULL,
   '22023: requester must be 1 to 200 characters with no control characters'),
  ('an empty requester', 'sqltest_req_a', 'read_on_demand', ARRAY['SQLREQ-A1'], '',
   '22023: requester must be 1 to 200 characters with no control characters'),
  ('a requester of 201 characters', 'sqltest_req_a', 'read_on_demand', ARRAY['SQLREQ-A1'],
   repeat('x', 201), '22023: requester must be 1 to 200 characters with no control characters'),
  ('a requester with a control character', 'sqltest_req_a', 'read_on_demand',
   ARRAY['SQLREQ-A1'], E'staff\n42',
   '22023: requester must be 1 to 200 characters with no control characters'),
  ('no meters', 'sqltest_req_a', 'read_on_demand', '{}'::text[], 'staff:42',
   '22023: meters must name at least one serial, each once, and no NULL'),
  ('a NULL list of meters', 'sqltest_req_a', 'read_on_demand', NULL::text[], 'staff:42',
   '22023: meters must name at least one serial, each once, and no NULL'),
  ('a NULL meter', 'sqltest_req_a', 'read_on_demand', ARRAY['SQLREQ-A1', NULL], 'staff:42',
   '22023: meters must name at least one serial, each once, and no NULL'),
  ('a meter twice', 'sqltest_req_a', 'read_on_demand', ARRAY['SQLREQ-A1', 'SQLREQ-A1'],
   'staff:42', '22023: meters must name at least one serial, each once, and no NULL'),
  ('a meter of another collector', 'sqltest_req_a', 'read_on_demand',
   ARRAY['SQLREQ-A1', 'SQLREQ-B1'], 'staff:42',
   '22023: meters not polled by collector sqltest_req_a now: SQLREQ-B1'),
  ('a meter that has moved away', 'sqltest_req_b', 'read_on_demand', ARRAY['SQLREQ-M1'],
   'staff:42', '22023: meters not polled by collector sqltest_req_b now: SQLREQ-M1'),
  ('a retired meter', 'sqltest_req_a', 'read_on_demand', ARRAY['SQLREQ-A3'], 'staff:42',
   '22023: meters not polled by collector sqltest_req_a now: SQLREQ-A3'),
  ('a meter not yet in service', 'sqltest_req_a', 'read_on_demand', ARRAY['SQLREQ-A4'],
   'staff:42', '22023: meters not polled by collector sqltest_req_a now: SQLREQ-A4'),
  ('a meter on an endpoint another system polls', 'sqltest_req_a', 'read_on_demand',
   ARRAY['SQLREQ-O1'], 'staff:42',
   '22023: meters not polled by collector sqltest_req_a now: SQLREQ-O1'),
  ('an unregistered meter', 'sqltest_req_a', 'read_on_demand', ARRAY['10.0.0.41'], 'staff:42',
   '22023: meters not polled by collector sqltest_req_a now: 10.0.0.41')
) c (name, collector, kind, meters, requester, error);

SELECT pg_temp.is((SELECT count(*) FROM jobs.requests), 2::bigint,
  'a refused request records nothing');

-- What ingest offers each collector

INSERT INTO ids VALUES ('b', pg_temp.request_as('minkanakku_staff', 'sqltest_req_b',
  'read_on_demand', ARRAY['SQLREQ-B1'], 'staff:7'));
INSERT INTO ids VALUES ('m', (SELECT request_id FROM jobs.request_status
                              WHERE meters = ARRAY['SQLREQ-M1']));
-- Asked two hours ago, so expired an hour ago.
WITH r AS (
  INSERT INTO jobs.requests (collector_id, kind, requester, requested_at, expires_at)
  VALUES ('sqltest_req_a', 'read_on_demand', 'staff:42', now() - interval '2 hours',
          now() - interval '1 hour')
  RETURNING request_id
), m AS (
  INSERT INTO jobs.request_meters SELECT request_id, 'SQLREQ-A1' FROM r
)
INSERT INTO ids SELECT 'expired', request_id FROM r;

INSERT INTO answers VALUES ('heartbeat a', pg_temp.ingest_as('collector_sqltest_req_a',
  pg_temp.batch(:'basic', 'a0000000-0000-4000-8000-000000000001', '[]', '[]')));
INSERT INTO answers VALUES ('heartbeat b', pg_temp.ingest_as('collector_sqltest_req_b',
  pg_temp.batch(:'basic', 'b0000000-0000-4000-8000-000000000001', '[]', '[]')));

SELECT pg_temp.is(
  (SELECT answer FROM answers WHERE name = 'heartbeat a')
    - 'first_received_at' - 'batch_id' - 'jobs',
  '{"resent": false,
    "readings": {"received": 0, "inserted": 0, "duplicate": 0, "conflicting": 0},
    "missed_reads": {"received": 0, "inserted": 0, "duplicate": 0},
    "firmware_reads": {"received": 0, "inserted": 0, "duplicate": 0, "conflicting": 0},
    "clock_checks": {"received": 0, "inserted": 0, "duplicate": 0, "conflicting": 0}}'::jsonb,
  'a heartbeat, a batch with no readings and no missed reads, is accepted');

SELECT pg_temp.is(
  (SELECT answer -> 'jobs' FROM answers WHERE name = 'heartbeat a'),
  (SELECT jsonb_agg(pg_temp.job(id) ORDER BY id) FROM ids WHERE name IN ('a', 'm')),
  'the answer lists the collector''s pending jobs, oldest first, with their meters and expiry');

SELECT pg_temp.is(
  (SELECT answer -> 'jobs' FROM answers WHERE name = 'heartbeat b'),
  jsonb_build_array(pg_temp.job((SELECT id FROM ids WHERE name = 'b'))),
  'a collector is offered only its own jobs');

SELECT pg_temp.is(
  (SELECT state FROM jobs.request_status WHERE request_id = (SELECT id FROM ids WHERE name = 'expired')),
  'expired'::jobs.state,
  'a request not answered by its expiry is expired, and is not offered');

SELECT admin.create_collector('sqltest_req_c');
SELECT pg_temp.ok(
  NOT (pg_temp.ingest_as('collector_sqltest_req_c',
         pg_temp.batch(:'basic', 'c0000000-0000-4000-8000-000000000001', '[]', '[]'))
       ?| ARRAY['jobs', 'unknown_requests']),
  'the answer to a collector with no pending jobs has no jobs and no unknown requests');

-- What ingest does with what comes back

INSERT INTO answers VALUES ('answer a', pg_temp.ingest_as('collector_sqltest_req_a',
  pg_temp.batch(:'basic', 'a0000000-0000-4000-8000-000000000002',
    jsonb_build_array(
      pg_temp.reading('SQLREQ-A1', 1, '2026-11-10T00:00:00Z', (SELECT id FROM ids WHERE name = 'a'), '10.0'),
      pg_temp.reading('SQLREQ-A1', 1, '2026-11-10T00:15:00Z', NULL, '11.0')),
    jsonb_build_array(
      pg_temp.missed('SQLREQ-A2', 2, '2026-11-10T00:00:01Z', (SELECT id FROM ids WHERE name = 'a'))))));

SELECT pg_temp.is(
  (SELECT answer -> 'readings' FROM answers WHERE name = 'answer a'),
  '{"received": 2, "inserted": 2, "duplicate": 0, "conflicting": 0}'::jsonb,
  'readings for a request are stored as any other');

SELECT pg_temp.is(
  (SELECT format('%s %s %s %s', s.state, s.readings, s.missed_reads, s.answered_at = now())
   FROM jobs.request_status s WHERE s.request_id = (SELECT id FROM ids WHERE name = 'a')),
  'answered 1 1 t',
  'a request is answered when a reading or missed read for it arrives, and counts them');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s %s', meter_serial, register_key, read_at), '; ')
   FROM jobs.request_readings WHERE request_id = (SELECT id FROM ids WHERE name = 'a'))
  || ' / '
  || (SELECT string_agg(format('%s %s:%s/%s %s %s', collector_id, endpoint_host, endpoint_port,
                               unit_id, register_key, read_at), '; ')
      FROM jobs.request_missed_reads WHERE request_id = (SELECT id FROM ids WHERE name = 'a')),
  'SQLREQ-A1 active_energy_import 2026-11-10 00:00:00+00 / '
  || 'sqltest_req_a 10.0.0.41:502/2 active_energy_import 2026-11-10 00:00:01+00',
  'the request is linked to its reading and missed read by their keys');

SELECT pg_temp.is(
  (SELECT count(*) FROM pg_attribute
   WHERE attrelid IN ('store.readings'::regclass, 'store.missed_reads'::regclass)
     AND attname LIKE '%request%'),
  0::bigint,
  'raw readings and missed reads carry no request: the link is a row of its own');

SELECT pg_temp.is(
  (SELECT answer -> 'jobs' FROM answers WHERE name = 'answer a'),
  jsonb_build_array(pg_temp.job((SELECT id FROM ids WHERE name = 'm'))),
  'an answered request is no longer offered');

SELECT pg_temp.ok(
  NOT ((SELECT answer FROM answers WHERE name = 'answer a') ? 'unknown_requests'),
  'an answer with only the collector''s own requests has no unknown requests');

INSERT INTO snapshots VALUES ('before resends', pg_temp.row_counts());

SELECT pg_temp.is(
  (SELECT a -> 'readings' || jsonb_build_object('resent', a -> 'resent')
   FROM pg_temp.ingest_as('collector_sqltest_req_a',
     pg_temp.batch(:'basic', 'a0000000-0000-4000-8000-000000000002',
       jsonb_build_array(
         pg_temp.reading('SQLREQ-A1', 1, '2026-11-10T00:00:00Z', (SELECT id FROM ids WHERE name = 'a'), '10.0'),
         pg_temp.reading('SQLREQ-A1', 1, '2026-11-10T00:15:00Z', NULL, '11.0')),
       jsonb_build_array(
         pg_temp.missed('SQLREQ-A2', 2, '2026-11-10T00:00:01Z', (SELECT id FROM ids WHERE name = 'a'))))) a),
  '{"received": 2, "inserted": 0, "duplicate": 2, "conflicting": 0, "resent": true}'::jsonb,
  'a resent batch of readings for a request stores nothing twice');

SELECT pg_temp.is(
  pg_temp.ingest_as('collector_sqltest_req_a',
    pg_temp.batch(:'basic', 'a0000000-0000-4000-8000-000000000003',
      jsonb_build_array(
        pg_temp.reading('SQLREQ-A1', 1, '2026-11-10T00:00:00Z', (SELECT id FROM ids WHERE name = 'a'), '10.0')),
      '[]')) -> 'readings',
  '{"received": 1, "inserted": 0, "duplicate": 1, "conflicting": 0}'::jsonb,
  'a reading for a request sent again in another batch is a duplicate, not a conflict');

SELECT pg_temp.is(
  pg_temp.count_changes((SELECT counts FROM snapshots WHERE name = 'before resends'),
                        pg_temp.row_counts()),
  'store.batches 1, store.uploads 2',
  'resending readings for a request adds uploads, and links nothing twice');

SELECT pg_temp.is(
  pg_temp.ingest_as('collector_sqltest_req_a',
    pg_temp.batch(:'basic', 'a0000000-0000-4000-8000-000000000004',
      jsonb_build_array(
        pg_temp.reading('SQLREQ-A1', 1, '2026-11-10T00:15:00Z', (SELECT id FROM ids WHERE name = 'm'), '11.0')),
      '[]')) -> 'readings',
  '{"received": 1, "inserted": 0, "duplicate": 1, "conflicting": 0}'::jsonb,
  'a stored reading that arrives again carrying a request id is a duplicate, not a conflict');

SELECT pg_temp.is(
  (SELECT format('%s %s', s.state, s.readings)
   FROM jobs.request_status s WHERE s.request_id = (SELECT id FROM ids WHERE name = 'm')),
  'answered 1',
  '... and links the stored reading to that request, which it leaves unchanged');

SELECT pg_temp.is(
  (SELECT format('%s %s', value, batch_id) FROM store.readings
   WHERE meter_serial = 'SQLREQ-A1' AND read_at = '2026-11-10T00:15:00Z'),
  '11.0 a0000000-0000-4000-8000-000000000002',
  '... the raw reading keeps the batch that first brought it');

INSERT INTO answers VALUES ('stray', pg_temp.ingest_as('collector_sqltest_req_a',
  pg_temp.batch(:'basic', 'a0000000-0000-4000-8000-000000000005',
    jsonb_build_array(
      pg_temp.reading('SQLREQ-A1', 1, '2026-11-10T00:30:00Z', (SELECT id FROM ids WHERE name = 'b'), '12.0'),
      pg_temp.reading('SQLREQ-A1', 1, '2026-11-10T00:45:00Z', 'ffffffff-ffff-4fff-8fff-ffffffffffff', '13.0')),
    jsonb_build_array(
      pg_temp.missed('SQLREQ-A2', 2, '2026-11-10T00:30:01Z', (SELECT id FROM ids WHERE name = 'b'))))));

SELECT pg_temp.is(
  (SELECT answer -> 'readings' FROM answers WHERE name = 'stray'),
  '{"received": 2, "inserted": 2, "duplicate": 0, "conflicting": 0}'::jsonb,
  'readings carrying another collector''s or an unknown request id are stored');

SELECT pg_temp.is(
  (SELECT answer -> 'unknown_requests' FROM answers WHERE name = 'stray'),
  (SELECT jsonb_agg(i ORDER BY i)
   FROM unnest(ARRAY[(SELECT id FROM ids WHERE name = 'b'),
                     'ffffffff-ffff-4fff-8fff-ffffffffffff'::uuid]) i),
  '... and the answer lists those request ids, once each');

SELECT pg_temp.is(
  (SELECT format('%s %s %s', s.state, s.readings, s.missed_reads)
   FROM jobs.request_status s WHERE s.request_id = (SELECT id FROM ids WHERE name = 'b')),
  'pending 0 0',
  '... and links nothing to another collector''s request');

SELECT pg_temp.ingest_as('collector_sqltest_req_a',
  pg_temp.batch(:'basic', 'a0000000-0000-4000-8000-000000000006',
    jsonb_build_array(
      pg_temp.reading('SQLREQ-A1', 1, '2026-11-10T01:00:00Z', (SELECT id FROM ids WHERE name = 'expired'), '14.0')),
    '[]'));

SELECT pg_temp.is(
  (SELECT format('%s %s', s.state, s.readings)
   FROM jobs.request_status s WHERE s.request_id = (SELECT id FROM ids WHERE name = 'expired')),
  'answered 1',
  'a reading for an expired request still answers it');

SELECT pg_temp.is(pg_temp.sqlstate_as(current_user, q), 'P0001', 'refused even to the owner: ' || q)
FROM unnest(ARRAY[
  'UPDATE jobs.requests SET requester = ''x''',
  'DELETE FROM jobs.requests',
  'UPDATE jobs.request_meters SET serial = ''x''',
  'DELETE FROM jobs.request_meters',
  'DELETE FROM jobs.request_readings',
  'TRUNCATE jobs.request_readings',
  'UPDATE jobs.request_missed_reads SET unit_id = 9',
  'DELETE FROM jobs.request_missed_reads'
]) q;

ROLLBACK;

-- The notice, on commit: a listener and a writer connection of their own.

BEGIN;
CREATE SCHEMA sqltest_dblink;
CREATE EXTENSION dblink SCHEMA sqltest_dblink;
SELECT sqltest_dblink.dblink_connect('listener', 'dbname=' || current_database());
SELECT sqltest_dblink.dblink_connect('writer', 'dbname=' || current_database());
SELECT sqltest_dblink.dblink_exec('listener', 'LISTEN request_answered');

-- The payloads of the request_answered notices the listener has, once it has
-- want of them or a second has passed.
CREATE FUNCTION pg_temp.notices(want integer) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  got jsonb := '[]';
BEGIN
  FOR i IN 1..20 LOOP
    PERFORM * FROM sqltest_dblink.dblink('listener', 'SELECT 1') AS t (one integer);
    got := got || coalesce(
      (SELECT jsonb_agg(n.extra::jsonb) FROM sqltest_dblink.dblink_get_notify('listener') n
       WHERE n.notify_name = 'request_answered'), '[]');
    EXIT WHEN jsonb_array_length(got) >= want;
    PERFORM pg_sleep(0.05);
  END LOOP;
  RETURN got;
END
$$;

-- A collector role left by an earlier run that stopped half way.
SELECT sqltest_dblink.dblink_exec('writer', 'DROP ROLE IF EXISTS collector_sqltest_notify');
SELECT sqltest_dblink.dblink_exec('writer', $w$
  DO $d$
  BEGIN
    PERFORM admin.create_collector('sqltest_notify');
    PERFORM admin.register_endpoint(
      endpoint_id => 'sqltest_notify_ep', valid_from => '2026-01-01Z',
      collector_id => 'sqltest_notify', host => '10.0.0.41', port => 502, framing => 'tcp',
      polled_by_other_system => false, timeout_ms => 1000, max_timeouts => 3, retries => 2,
      busy_backoff_ms => 500, reconnect_backoff_min_ms => 1000,
      reconnect_backoff_max_ms => 60000, interval_ms => 900000);
    PERFORM admin.register_meter(serial => 'SQLNOTIFY-1', valid_from => '2026-01-01Z',
      endpoint_id => 'sqltest_notify_ep', unit_id => 1, profile => 'elite_440',
      interval_ms => NULL);
  END
  $d$
$w$);

SELECT id AS notify_request
FROM sqltest_dblink.dblink('writer', $w$
  SET ROLE minkanakku_staff;
  SELECT jobs.request_job(collector_id => 'sqltest_notify', kind => 'read_on_demand',
                          meters => ARRAY['SQLNOTIFY-1'], requester => 'staff:1')
$w$) AS t (id uuid) \gset

SELECT format('RESET ROLE; SET ROLE collector_sqltest_notify; SELECT api.ingest(%L::jsonb)',
  pg_temp.batch(:'basic', 'd0000000-0000-4000-8000-000000000001',
    jsonb_build_array(pg_temp.reading('SQLNOTIFY-1', 1, '2026-11-10T00:00:00Z', :'notify_request', '10.0')),
    jsonb_build_array(pg_temp.missed('SQLNOTIFY-1', 1, '2026-11-10T00:00:01Z', :'notify_request'))))
  AS notify_ingest \gset

SELECT * FROM sqltest_dblink.dblink('writer', :'notify_ingest') AS t (answer jsonb);

SELECT pg_temp.is(pg_temp.notices(1),
  jsonb_build_array(jsonb_build_object('request_id', :'notify_request'::uuid,
    'batch_id', 'd0000000-0000-4000-8000-000000000001', 'readings', 1, 'missed_reads', 1)),
  'a committed batch with readings for a request notifies request_answered once, with what it linked');

SELECT * FROM sqltest_dblink.dblink('writer', :'notify_ingest') AS t (answer jsonb);

SELECT pg_temp.is(pg_temp.notices(1), '[]'::jsonb,
  'a resend that links nothing new notifies nothing');

SELECT sqltest_dblink.dblink_exec('writer', 'RESET ROLE; DROP ROLE collector_sqltest_notify');
SELECT sqltest_dblink.dblink_disconnect('writer');
SELECT sqltest_dblink.dblink_disconnect('listener');
ROLLBACK;
