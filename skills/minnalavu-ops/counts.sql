-- Every figure a store move compares (minnalavu-ops store-move.md): each
-- table's row count, the last migration, open problems, copy holes and the
-- last upload. Run on both stores and diff; only the temp table's schema
-- name may differ.
--   psql -U postgres -d minnalavu -q -f counts.sql > counts-<side>.txt
\pset format unaligned
\pset tuples_only on
CREATE TEMP TABLE c(t text, n bigint);
DO $$ DECLARE r record; k bigint; BEGIN
  FOR r IN SELECT schemaname s, tablename t FROM pg_tables
           WHERE schemaname NOT IN ('pg_catalog','information_schema')
             AND schemaname NOT LIKE '_timescaledb%' AND schemaname <> 'timescaledb_information'
           ORDER BY 1,2 LOOP
    EXECUTE format('SELECT count(*) FROM %I.%I', r.s, r.t) INTO k;
    INSERT INTO c VALUES (r.s||'.'||r.t, k);
  END LOOP; END $$;
SELECT t||' '||n FROM c ORDER BY t;
SELECT 'max migration '||max(version) FROM schema_migrations;
SELECT 'health.problems '||count(*) FROM health.problems;
SELECT 'copy_holes '||count(*) FROM admin.copy_holes(since => '2000-01-01');
SELECT 'max uploads.received_at '||max(received_at) FROM store.uploads;
