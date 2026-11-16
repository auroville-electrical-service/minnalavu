-- api.ingest accepts exactly the batches the batch schema accepts: every case
-- in contract/fixtures/batch.v1.cases.json, as the collector's schema test runs
-- them against the schema itself. Every profile version a case names is
-- loaded, so that only the schema decides.

\ir lib/assert.sql
\set basic `cat ../contract/fixtures/batch.v1.basic.json`
\set cases `cat ../contract/fixtures/batch.v1.cases.json`
\set p440 `cat ../contract/profiles/elite_440.json`

BEGIN;

SELECT admin.create_collector('sqltest_schema');
SELECT admin.load_profile(jsonb_set(:'p440', '{version}', '3'));

SELECT pg_temp.ok(
  pg_temp.ingest_error('collector_sqltest_schema', :'basic') = 'ok',
  'accepts the basic fixture');

SELECT pg_temp.ok(
  pg_temp.ingest_error('collector_sqltest_schema', pg_temp.changed(:'basic', c))
    LIKE 'PT422: batch rejected: %',
  'rejects ' || (c ->> 'name'))
FROM jsonb_array_elements(:'cases'::jsonb -> 'cases') c;

SELECT pg_temp.is(
  pg_temp.ingest_error('collector_sqltest_schema', changed.batch),
  'ok',
  'accepts ' || (v ->> 'name'))
FROM jsonb_array_elements(:'cases'::jsonb -> 'valid') v
CROSS JOIN LATERAL (
  WITH RECURSIVE steps (i, batch) AS (
    SELECT 0, :'basic'::jsonb
    UNION ALL
    SELECT i + 1, pg_temp.changed(batch, v -> 'changes' -> i)
    FROM steps WHERE i < jsonb_array_length(v -> 'changes')
  )
  SELECT batch FROM steps ORDER BY i DESC LIMIT 1
) changed;

SELECT pg_temp.is(
  pg_temp.ingest_error('collector_sqltest_schema',
    pg_temp.changed(:'basic', '{"path": ["readings", 1, "value"], "value": 1234.56}')),
  'PT422: batch rejected: batch.readings[1].value must be a decimal string such as "1234.56"',
  'a rejection names the field and the problem');

ROLLBACK;
