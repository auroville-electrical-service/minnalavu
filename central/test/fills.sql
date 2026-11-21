-- Copy fills (ADR 0025): what admin.request_fill accepts and records, how
-- ingest offers a fill to its collector and links what comes back, when a
-- fill is answered, and the holes admin.copy_holes finds. Who may call what
-- is in grants.sql.

\ir lib/assert.sql
\set basic `cat ../contract/fixtures/batch.v1.basic.json`

BEGIN;

SELECT admin.create_collector(c) FROM unnest(ARRAY['sqltest_fill', 'sqltest_fill_b']) c;

-- sqlf_e copies; sqlf_nc does not; sqlf_o is polled by another system;
-- sqlf_b is another collector's. Everything in service for ten days.
SELECT admin.register_endpoint(
  endpoint_id => e, valid_from => now() - interval '10 days', collector_id => c, host => h,
  port => 502, framing => 'tcp', polled_by_other_system => o, timeout_ms => 1000,
  max_timeouts => 3, retries => 2, busy_backoff_ms => 500, reconnect_backoff_min_ms => 1000,
  reconnect_backoff_max_ms => 60000, interval_ms => 900000, retry_ms => 1800000, copy => k)
FROM (VALUES ('sqlf_e', 'sqltest_fill', '10.0.0.21', false, true),
             ('sqlf_nc', 'sqltest_fill', '10.0.0.22', false, false),
             ('sqlf_o', 'sqltest_fill', '10.0.0.23', true, true),
             ('sqlf_b', 'sqltest_fill_b', '10.0.0.24', false, true)) v (e, c, h, o, k);

SELECT admin.register_target(endpoint_id => e, unit_id => u, valid_from => now() - interval '10 days',
         profile => p, interval_ms => NULL, retry_ms => NULL),
       admin.register_meter(serial => s, valid_from => now() - interval '10 days',
         endpoint_id => e, unit_id => u)
FROM (VALUES ('sqlf_e', 1, 'elite_440', 'SIM-445-0001'), ('sqlf_e', 3, 'elite_500', 'SIM-500-0001'),
             ('sqlf_nc', 1, 'elite_440', 'SQLF-NC'), ('sqlf_o', 1, 'elite_440', 'SQLF-O'),
             ('sqlf_b', 1, 'elite_440', 'SQLF-B')) v (e, u, p, s);

-- admin.request_fill with these arguments, as 'SQLSTATE: message', or 'ok'.
CREATE FUNCTION pg_temp.fill_error(collector text, meters text[], stores text[],
                                   from_time timestamp, to_time timestamp, requester text,
                                   expires_after interval)
RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM admin.request_fill(collector, meters, stores, from_time, to_time, requester,
                             expires_after);
  RETURN 'ok';
EXCEPTION
  WHEN OTHERS THEN
    RETURN SQLSTATE || ': ' || SQLERRM;
END
$$;

SELECT pg_temp.is(
  pg_temp.fill_error(c, m, s, f, t, r, x), want, name)
FROM (VALUES
  ('sqltest_nobody', ARRAY['SIM-445-0001'], ARRAY['history'], '2026-08-01'::timestamp,
   '2026-11-02'::timestamp, 'operator', '3 days'::interval,
   '22023: collector sqltest_nobody is not registered', 'refuses an unregistered collector'),
  ('sqltest_fill', ARRAY['SIM-445-0001'], ARRAY['history'], '2026-08-01', '2026-11-02',
   E'op\nerator', '3 days',
   '22023: requester must be 1 to 200 characters with no control characters',
   'refuses a requester with a control character'),
  ('sqltest_fill', ARRAY[]::text[], ARRAY['history'], '2026-08-01', '2026-11-02', 'operator',
   '3 days', '22023: meters must name at least one serial, each once, and no NULL',
   'refuses no meters'),
  ('sqltest_fill', ARRAY['SIM-445-0001', 'SIM-445-0001'], ARRAY['history'], '2026-08-01',
   '2026-11-02', 'operator', '3 days',
   '22023: meters must name at least one serial, each once, and no NULL',
   'refuses a meter named twice'),
  ('sqltest_fill', ARRAY['SIM-445-0001'], ARRAY[]::text[], '2026-08-01', '2026-11-02',
   'operator', '3 days',
   '22023: stores must name at least one of history, snapshot, load_survey, each once',
   'refuses no stores'),
  ('sqltest_fill', ARRAY['SIM-445-0001'], ARRAY['history', 'history'], '2026-08-01',
   '2026-11-02', 'operator', '3 days',
   '22023: stores must name at least one of history, snapshot, load_survey, each once',
   'refuses a store named twice'),
  ('sqltest_fill', ARRAY['SIM-445-0001'], ARRAY['event_log'], '2026-08-01', '2026-11-02',
   'operator', '3 days',
   '22023: stores must name at least one of history, snapshot, load_survey, each once',
   'refuses a store the meters do not keep'),
  ('sqltest_fill', ARRAY['SIM-445-0001'], ARRAY['history'], '2026-11-02', '2026-11-02',
   'operator', '3 days',
   '22023: from_time must be before to_time, both whole seconds of the meters'' clock',
   'refuses an empty range'),
  ('sqltest_fill', ARRAY['SIM-445-0001'], ARRAY['history'], '2026-08-01 00:00:00.5',
   '2026-11-02', 'operator', '3 days',
   '22023: from_time must be before to_time, both whole seconds of the meters'' clock',
   'refuses a range finer than the meters'' seconds'),
  ('sqltest_fill', ARRAY['SIM-445-0001'], ARRAY['history'], '2026-08-01', '2026-11-02',
   'operator', '0 seconds', '22023: expires_after must be a positive interval',
   'refuses a request that never runs'),
  ('sqltest_fill', ARRAY['SIM-445-0001', 'SQLF-NC', 'SQLF-O', 'SQLF-B', 'SQLF-NONE'],
   ARRAY['history'], '2026-08-01', '2026-11-02', 'operator', '3 days',
   '22023: meters not copied by collector sqltest_fill now: SQLF-B, SQLF-NC, SQLF-NONE, SQLF-O',
   'refuses meters the collector does not copy now: not copying, another system''s, another '
   || 'collector''s, unregistered')
) v (c, m, s, f, t, r, x, want, name);

CREATE TEMP TABLE ids (name text PRIMARY KEY, id uuid);
INSERT INTO ids VALUES
  ('fill', admin.request_fill(collector_id => 'sqltest_fill',
     meters => ARRAY['SIM-500-0001', 'SIM-445-0001'], stores => ARRAY['load_survey', 'history'],
     from_time => '2026-08-01', to_time => '2026-11-02', requester => 'operator',
     expires_after => '3 days')),
  ('other', admin.request_fill(collector_id => 'sqltest_fill_b', meters => ARRAY['SQLF-B'],
     stores => ARRAY['history'], from_time => '2026-08-01', to_time => '2026-11-02',
     requester => 'operator', expires_after => '1 day'));

SELECT pg_temp.is(
  (SELECT format('%s %s %s %s %s %s', q.kind, q.requester, q.expires_at - q.requested_at,
                 f.from_time, f.to_time,
                 (SELECT string_agg(s.store::text, ',' ORDER BY s.store)
                  FROM jobs.request_fill_stores s WHERE s.request_id = q.request_id))
   FROM jobs.requests q JOIN jobs.request_fills f USING (request_id)
   WHERE q.request_id = (SELECT id FROM ids WHERE name = 'fill')),
  'fill_copies operator 3 days 2026-08-01 00:00:00 2026-11-02 00:00:00 history,load_survey',
  'a fill records its kind, requester, expiry, range and stores');

-- A fill that expired an hour ago, made as the record would hold it.
INSERT INTO jobs.requests (request_id, collector_id, kind, requester, requested_at, expires_at)
VALUES ('5e1f0000-0000-4000-8000-000000000001', 'sqltest_fill', 'fill_copies', 'operator',
        now() - interval '2 hours', now() - interval '1 hour');
INSERT INTO jobs.request_meters VALUES ('5e1f0000-0000-4000-8000-000000000001', 'SIM-445-0001');
INSERT INTO jobs.request_fills
VALUES ('5e1f0000-0000-4000-8000-000000000001', '2026-08-01', '2026-11-02');
INSERT INTO jobs.request_fill_stores
VALUES ('5e1f0000-0000-4000-8000-000000000001', 'history');

-- The basic batch with this id, these stored entries and these fill results;
-- no readings, missed reads or meter-clock reads.
CREATE FUNCTION pg_temp.fills(basic jsonb, id text, entries jsonb, results jsonb) RETURNS jsonb
LANGUAGE sql AS $$
  SELECT (basic - 'meter_clock_reads')
         || jsonb_build_object('batch_id', id, 'readings', '[]'::jsonb, 'missed_reads',
                               '[]'::jsonb, 'stored_entries', entries, 'fill_results', results)
$$;

-- A stored entry of the basic batch's meter at unit 1, for a request.
CREATE FUNCTION pg_temp.entry(store text, meter_time text, register_key text, request uuid)
RETURNS jsonb
LANGUAGE sql AS $$
  SELECT jsonb_strip_nulls(jsonb_build_object(
    'endpoint', jsonb_build_object('host', '10.0.0.21', 'port', 502), 'unit_id', 1,
    'meter_serial', 'SIM-445-0001', 'product_code', 'ELITE440-445', 'profile', 'elite_440',
    'profile_version', 2, 'store', store, 'meter_time', meter_time, 'register_key', register_key,
    'value', '1.5', 'slot', 2, 'copied_at', '2026-11-02T02:10:00Z', 'request_id', request,
    'interval_s', CASE WHEN store = 'load_survey' THEN 1800 END))
$$;

CREATE FUNCTION pg_temp.result(request uuid, serial text, unit integer, store text,
                               gone_before text)
RETURNS jsonb
LANGUAGE sql AS $$
  SELECT jsonb_build_object(
    'request_id', request, 'endpoint', jsonb_build_object('host', '10.0.0.21', 'port', 502),
    'unit_id', unit, 'meter_serial', serial, 'store', store, 'gone_before', gone_before,
    'finished_at', '2026-11-02T02:14:07.123456Z')
$$;

CREATE TEMP TABLE answers (name text PRIMARY KEY, answer jsonb);
INSERT INTO answers VALUES
  ('basic', pg_temp.ingest_as('collector_sqltest_fill', :'basic')),
  ('other', pg_temp.ingest_as('collector_sqltest_fill_b',
     pg_temp.fills(:'basic', '5e1f0000-0000-4000-8000-0000000000b0', '[]', '[]')));

SELECT pg_temp.is(
  (SELECT answer -> 'jobs' FROM answers WHERE name = 'basic'),
  jsonb_build_array(jsonb_build_object(
    'request_id', (SELECT id FROM ids WHERE name = 'fill'), 'kind', 'fill_copies',
    'meters', '["SIM-445-0001", "SIM-500-0001"]'::jsonb,
    'requested_at', (SELECT requested_at FROM jobs.requests
                     WHERE request_id = (SELECT id FROM ids WHERE name = 'fill')),
    'expires_at', (SELECT expires_at FROM jobs.requests
                   WHERE request_id = (SELECT id FROM ids WHERE name = 'fill')),
    'stores', '["history", "load_survey"]'::jsonb,
    'from', '2026-08-01T00:00:00', 'to', '2026-11-02T00:00:00')),
  'ingest offers a collector its pending fill with its stores and its range as meter times, '
  || 'and not one expired');

SELECT pg_temp.is(
  (SELECT answer -> 'jobs' -> 0 ->> 'request_id' FROM answers WHERE name = 'other'),
  (SELECT id::text FROM ids WHERE name = 'other'),
  'each collector is offered only its own fills');

-- Entries for the fill: two load-survey days and a history month in its
-- range; a snapshot, a store it did not name; a history month before its
-- range; and the basic batch's history entry again, which the store holds.
-- Results: one load survey, where the meter's oldest entry is 2026-10-31;
-- one for the snapshot it did not name; one for another collector's fill.
INSERT INTO answers SELECT 'linked', pg_temp.ingest_as('collector_sqltest_fill', pg_temp.fills(
  :'basic', '5e1f0000-0000-4000-8000-0000000000a1',
  jsonb_build_array(
    pg_temp.entry('load_survey', '2026-10-28T00:00:00', 'active_energy_import', f.id),
    pg_temp.entry('load_survey', '2026-10-29T00:00:00', 'active_energy_import', f.id),
    pg_temp.entry('history', '2026-08-01T00:00:00', 'active_energy_import', f.id),
    pg_temp.entry('snapshot', '2026-10-30T00:00:00', 'active_energy_import', f.id),
    pg_temp.entry('history', '2026-07-01T00:00:00', 'active_energy_import', f.id),
    jsonb_set(:'basic'::jsonb -> 'stored_entries' -> 0, '{request_id}', to_jsonb(f.id))),
  jsonb_build_array(
    pg_temp.result(f.id, 'SIM-445-0001', 1, 'load_survey', '2026-10-31T00:00:00'),
    pg_temp.result(f.id, 'SIM-445-0001', 1, 'snapshot', NULL),
    pg_temp.result(o.id, 'SQLF-B', 1, 'history', NULL))))
FROM ids f, ids o WHERE f.name = 'fill' AND o.name = 'other';

SELECT pg_temp.is(
  (SELECT jsonb_build_object('fill_results', answer -> 'fill_results',
                             'unknown', answer -> 'unknown_requests',
                             'offered', answer -> 'jobs' -> 0 ->> 'request_id')
   FROM answers WHERE name = 'linked'),
  jsonb_build_object(
    'fill_results', '{"received": 3, "inserted": 1, "duplicate": 0, "unlinked": 2}'::jsonb,
    'unknown', jsonb_build_array((SELECT id FROM ids WHERE name = 'other')),
    'offered', (SELECT id::text FROM ids WHERE name = 'fill')),
  'a fill result of a meter and store the fill named is kept; one of a store it did not name, '
  || 'or of another collector''s request, is not, and that request is unknown; the fill is '
  || 'offered until every result has come');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s', l.store, l.meter_time), ', '
                     ORDER BY l.store, l.meter_time)
   FROM jobs.request_stored_entries l
   WHERE l.request_id = (SELECT id FROM ids WHERE name = 'fill')),
  'history 2026-08-01 00:00:00, history 2026-11-01 00:00:00, '
  || 'load_survey 2026-10-28 00:00:00, load_survey 2026-10-29 00:00:00',
  'a fill links the entries of its stores and range, one the store already held among them, '
  || 'and not one of another store or before its range');

SELECT pg_temp.is(
  (SELECT format('%s %s %s %s', state, stored_entries, fill_results, answered_at IS NULL)
   FROM jobs.request_status WHERE request_id = (SELECT id FROM ids WHERE name = 'fill')),
  'pending 4 1 t',
  'a fill with results still to come is pending, with what came for it counted');

SELECT pg_temp.is(
  (SELECT state::text FROM jobs.request_status
   WHERE request_id = '5e1f0000-0000-4000-8000-000000000001'),
  'expired',
  'a fill not answered by its expiry has expired');

-- Holes of SIM-445-0001, the one copied meter whose clock has been read: its
-- load survey holds 2026-10-28, 10-29 and 10-31; its history 07, 08 and 11.
-- The meter's oldest load-survey entry is 2026-10-31, so 10-30 is gone; the
-- fill has no history result yet, so history's holes are pending on it.
SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s %s-%s %s %s/%s %s %s', h.serial, h.store, h.slot_start::date,
                            h.slot_end::date, h.profile, h.endpoint_id, h.unit_id, h.gone,
                            coalesce((h.pending_request
                                      = (SELECT id FROM ids WHERE name = 'fill'))::text, '-')),
                     '; ' ORDER BY h.serial, h.store, h.slot_start)
   FROM admin.copy_holes(since => '2026-07-01') h),
  'SIM-445-0001 history 2026-09-01-2026-10-01 elite_440 sqlf_e/1 f true; '
  || 'SIM-445-0001 history 2026-10-01-2026-11-01 elite_440 sqlf_e/1 f true; '
  || 'SIM-445-0001 load_survey 2026-10-30-2026-10-31 elite_440 sqlf_e/1 t -',
  'copy_holes lists each day (month, for history) between a store''s oldest and newest entries '
  || 'that holds none, whether the meter no longer holds it, and the fill that will copy it');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s', h.store, h.slot_start::date), ', '
                     ORDER BY h.store, h.slot_start)
   FROM admin.copy_holes(since => '2026-10-15') h),
  'history 2026-10-01, load_survey 2026-10-30',
  'copy_holes looks back to since, from the slot since falls in');

-- The rest of the fill's results, and the load survey's again, saying
-- otherwise.
INSERT INTO answers SELECT 'answered', pg_temp.ingest_as('collector_sqltest_fill', pg_temp.fills(
  :'basic', '5e1f0000-0000-4000-8000-0000000000a2', '[]',
  jsonb_build_array(
    pg_temp.result(f.id, 'SIM-445-0001', 1, 'history', NULL),
    pg_temp.result(f.id, 'SIM-500-0001', 3, 'history', '2026-11-02T00:00:00'),
    pg_temp.result(f.id, 'SIM-500-0001', 3, 'load_survey', NULL),
    pg_temp.result(f.id, 'SIM-445-0001', 1, 'load_survey', NULL))))
FROM ids f WHERE f.name = 'fill';

SELECT pg_temp.is(
  (SELECT jsonb_build_object('fill_results', answer -> 'fill_results', 'jobs', answer ? 'jobs')
   FROM answers WHERE name = 'answered'),
  '{"fill_results": {"received": 4, "inserted": 3, "duplicate": 1, "unlinked": 0},
    "jobs": false}'::jsonb,
  'a resent fill result is a duplicate, and a fill with every result in is no longer offered');

SELECT pg_temp.is(
  (SELECT format('%s %s %s', s.state, s.fill_results,
                 s.answered_at = (SELECT max(linked_at) FROM jobs.request_fill_results
                                  WHERE request_id = s.request_id))
   FROM jobs.request_status s WHERE s.request_id = (SELECT id FROM ids WHERE name = 'fill')),
  'answered 4 t',
  'a fill is answered when its last result comes');

SELECT pg_temp.is(
  (SELECT gone_before::text FROM jobs.request_fill_results
   WHERE (request_id, meter_serial, store)
         = ((SELECT id FROM ids WHERE name = 'fill'), 'SIM-445-0001', 'load_survey')),
  '2026-10-31 00:00:00',
  'the first fill result stands');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s %s', h.store, h.slot_start::date, h.pending_request IS NULL),
                     ', ' ORDER BY h.store, h.slot_start)
   FROM admin.copy_holes(since => '2026-07-01') h WHERE h.store = 'history'),
  'history 2026-09-01 t, history 2026-10-01 t',
  'a hole is no longer pending on a fill that has its result');

SELECT pg_temp.is(
  pg_temp.unkeyed_scans('SELECT * FROM admin.copy_holes(since => ''2026-07-01'')'),
  NULL,
  'copy_holes scans no stored entries without a key');

-- Keyed by serial and store alone, a lookup would read every entry of the
-- meter's store for each slot; each must also name a register key (the
-- oldest and newest) or a stamp range (a slot).
CREATE FUNCTION pg_temp.broad_lookups(q text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
  plan jsonb;
BEGIN
  SET LOCAL enable_seqscan = off;
  EXECUTE 'EXPLAIN (FORMAT JSON) ' || q INTO plan;
  RESET enable_seqscan;
  RETURN (SELECT string_agg(format('%s on %s: %s', n ->> 'Node Type', n ->> 'Relation Name',
                                   n ->> 'Index Cond'), '; ')
          FROM jsonb_path_query(plan, 'lax $.**') n
          WHERE jsonb_typeof(n) = 'object'
            AND n ->> 'Relation Name' ~ '^_hyper_' AND n ? 'Index Cond'
            AND n ->> 'Index Cond' LIKE '%meter_serial%'
            AND n ->> 'Index Cond' NOT LIKE '%register_key%'
            AND n ->> 'Index Cond' NOT LIKE '%meter_time%');
END
$$;

SELECT pg_temp.is(
  pg_temp.broad_lookups('SELECT * FROM admin.copy_holes(since => ''2026-07-01'')'),
  NULL,
  'copy_holes looks entries up by serial, store and register key or stamp, never by serial '
  || 'and store alone');

ROLLBACK;
