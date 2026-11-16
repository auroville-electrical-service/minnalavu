-- Assertions for the SQL tests, as functions in this session's temporary
-- schema. A passing assertion prints a notice "ok - <name>"; a failing one
-- raises "not ok - <name>", which stops the file (bin/test counts both).
-- Query results are not wanted; only the notices and errors are.

\o /dev/null

CREATE FUNCTION pg_temp.ok(passed boolean, name text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF passed IS NOT TRUE THEN
    RAISE EXCEPTION 'not ok - %', name;
  END IF;
  RAISE NOTICE 'ok - %', name;
END
$$;

CREATE FUNCTION pg_temp.is(got anycompatible, want anycompatible, name text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF got IS DISTINCT FROM want THEN
    RAISE EXCEPTION 'not ok - %: got %, want %', name, coalesce(got::text, 'NULL'),
      coalesce(want::text, 'NULL');
  END IF;
  RAISE NOTICE 'ok - %', name;
END
$$;

-- Run sql as role and return its SQLSTATE: '00000' if it succeeded. Whatever
-- it did is undone either way.
CREATE FUNCTION pg_temp.sqlstate_as(role text, sql text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format('SET LOCAL ROLE %I', role);
  EXECUTE sql;
  RAISE SQLSTATE 'TT000';
EXCEPTION
  WHEN SQLSTATE 'TT000' THEN
    RESET ROLE;
    RETURN '00000';
  WHEN OTHERS THEN
    RETURN SQLSTATE;
END
$$;

-- Call api.ingest as a collector's role, as PostgREST does after SET ROLE.
CREATE FUNCTION pg_temp.ingest_as(role text, batch jsonb) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  answer jsonb;
BEGIN
  EXECUTE format('SET LOCAL ROLE %I', role);
  answer := api.ingest(batch);
  RESET ROLE;
  RETURN answer;
END
$$;

-- The error api.ingest raises for batch, as 'SQLSTATE: message', or 'ok'.
CREATE FUNCTION pg_temp.ingest_error(role text, batch jsonb) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_temp.ingest_as(role, batch);
  RETURN 'ok';
EXCEPTION
  WHEN OTHERS THEN
    RETURN SQLSTATE || ': ' || SQLERRM;
END
$$;

-- Apply one change from contract/fixtures/batch.v1.cases.json to a batch, or
-- from config.v1.cases.json to a config.
CREATE FUNCTION pg_temp.changed(batch jsonb, change jsonb) RETURNS jsonb
LANGUAGE sql AS $$
  SELECT CASE
    WHEN change ? 'delete' THEN batch #- path
    ELSE jsonb_set(batch, path, change -> 'value', true)
  END
  FROM (SELECT ARRAY(SELECT jsonb_array_elements_text(change -> 'path')) AS path) p
$$;

-- A case's changes, in order, as config.v1.cases.json's valid entries and
-- config.v1.digests.json's cases list them.
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

-- Each scan of readings, missed reads or a hypertable chunk in the plan of a
-- query that is not a keyed lookup: its node type and relation. Seq scans
-- priced out, so any left is the only path there.
CREATE FUNCTION pg_temp.unkeyed_scans(q text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
  plan jsonb;
BEGIN
  SET LOCAL enable_seqscan = off;
  EXECUTE 'EXPLAIN (FORMAT JSON) ' || q INTO plan;
  RESET enable_seqscan;
  RETURN (SELECT string_agg(format('%s on %s', n ->> 'Node Type', n ->> 'Relation Name'), '; ')
          FROM jsonb_path_query(plan, 'lax $.**') n
          WHERE jsonb_typeof(n) = 'object'
            AND n ->> 'Relation Name' ~ '^(readings|missed_reads|meter_clock_reads|uploads|_hyper_)'
            AND n ->> 'Node Type' <> 'Custom Scan'
            AND NOT (n ? 'Index Cond' OR n ? 'Recheck Cond'));
END
$$;
