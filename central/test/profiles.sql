-- The profile catalog: what bin/load-profiles loaded from contract/profiles,
-- what admin.load_profile accepts, and that a loaded version never changes.

\ir lib/assert.sql
\set p440 `cat ../contract/profiles/elite_440.json`
\set p500 `cat ../contract/profiles/elite_500.json`

BEGIN;

-- A profile file's registers as 'key table address type word_order decimals
-- unit kind', in the file's order.
CREATE FUNCTION pg_temp.file_registers(document jsonb) RETURNS text
LANGUAGE sql AS $$
  SELECT string_agg(format('%s %s %s %s %s %s %s %s', r ->> 'key', r ->> 'table', r ->> 'address',
                           r ->> 'type', r ->> 'word_order', coalesce(r ->> 'decimals', '-'),
                           r ->> 'unit', r ->> 'kind'), '; ' ORDER BY i)
  FROM jsonb_array_elements(document -> 'registers') WITH ORDINALITY e (r, i)
$$;

CREATE FUNCTION pg_temp.catalog_registers(p text, v bigint) RETURNS text
LANGUAGE sql AS $$
  SELECT string_agg(format('%s %s %s %s %s %s %s %s', register_key, register_table, address, type,
                           word_order, coalesce(decimals::text, '-'), unit, kind), '; '
                    ORDER BY address)
  FROM store.profile_registers WHERE profile = p AND version = v
$$;

-- The error admin.load_profile raises for a document, as 'SQLSTATE: message', or its answer.
CREATE FUNCTION pg_temp.load(document jsonb) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
  RETURN admin.load_profile(document);
EXCEPTION
  WHEN OTHERS THEN
    RETURN SQLSTATE || ': ' || SQLERRM;
END
$$;

-- A document with one register entry changed.
CREATE FUNCTION pg_temp.entry(document jsonb, i integer, field text, value jsonb) RETURNS jsonb
LANGUAGE sql AS $$
  SELECT CASE WHEN value IS NULL THEN document #- ARRAY['registers', i::text, field]
              ELSE jsonb_set(document, ARRAY['registers', i::text, field], value) END
$$;

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s', profile, version), ', ' ORDER BY profile, version)
   FROM store.profile_versions),
  format('elite_440 %s, elite_500 %s', :'p440'::jsonb -> 'version', :'p500'::jsonb -> 'version'),
  'every profile in contract/profiles is loaded, at the version its file names');

SELECT pg_temp.is(pg_temp.catalog_registers(d ->> 'profile', (d ->> 'version')::bigint),
                  pg_temp.file_registers(d),
                  'the catalog holds every register of ' || (d ->> 'profile') || ' as its file gives it')
FROM (VALUES (:'p440'::jsonb), (:'p500'::jsonb)) f (d);

SELECT pg_temp.is(
  (SELECT string_agg(DISTINCT format('%s %s', type, coalesce(decimals::text, '-')), ', ')
   FROM store.profile_registers WHERE type IN ('f32', 'f64')),
  'f32 -, f64 -',
  'a float register has no decimals');

SELECT pg_temp.is(pg_temp.load(:'p440'), 'already loaded',
                  'loading a version again with the same registers changes nothing');

SELECT pg_temp.is(
  pg_temp.load(pg_temp.entry(:'p440', 0, 'verified_on_device', '"2026-11-20"')),
  'already loaded',
  'nor does a change to what the catalog does not hold, such as the date an entry was verified');

SELECT pg_temp.is(pg_temp.load(d),
  '22023: profile elite_440 version 1 is already loaded with other registers: ' || keys,
  'a loaded version is refused when its file changes: ' || what)
FROM (VALUES
  (pg_temp.entry(:'p440', 0, 'type', '"f64"'), 'active_energy_import', 'a type'),
  (pg_temp.entry(:'p440', 1, 'word_order', '"high_first"'), 'active_energy_export', 'a word order'),
  (pg_temp.entry(:'p440', 0, 'address', '200'), 'active_energy_import', 'an address'),
  (pg_temp.entry(:'p440', 0, 'unit', '"Wh"'), 'active_energy_import', 'a unit'),
  (pg_temp.entry(:'p440', 0, 'kind', '"interval"'), 'active_energy_import', 'a kind'),
  (jsonb_set(:'p440', '{registers}', (:'p440'::jsonb -> 'registers') - 1),
   'active_energy_export', 'a register dropped'),
  (pg_temp.entry(jsonb_set(:'p440', '{registers,2}', :'p440'::jsonb -> 'registers' -> 0), 2, 'key',
                 '"reactive_energy_import"'), 'reactive_energy_import', 'a register added')
) c (d, keys, what);

SELECT pg_temp.is(pg_temp.catalog_registers('elite_440', 1), pg_temp.file_registers(:'p440'),
                  'and the loaded version is as it was');

SELECT pg_temp.is(
  pg_temp.load(pg_temp.entry(jsonb_set(:'p440', '{version}', '2'), 0, 'kind', '"interval"')),
  'new',
  'a correction loads as a new version');

SELECT pg_temp.is(
  format('%s / %s', pg_temp.catalog_registers('elite_440', 1),
         pg_temp.catalog_registers('elite_440', 2)),
  format('%s / %s', pg_temp.file_registers(:'p440'),
         pg_temp.file_registers(pg_temp.entry(:'p440', 0, 'kind', '"interval"'))),
  'and the old version stays as it was beside it');

SELECT pg_temp.ok(pg_temp.load(d) LIKE state || ': %', 'a profile file is refused: ' || what)
FROM (VALUES
  (jsonb_set(:'p440', '{version}', '0'), '23514', 'version 0'),
  (jsonb_set(:'p440', '{version}', '9007199254740992'), '23514', 'a version above 2^53 - 1'),
  (jsonb_set(:'p440', '{version}', '"3"'), '22023', 'a version as a string'),
  (jsonb_set(:'p440', '{version}', '3.5'), '22023', 'a fractional version'),
  (jsonb_set(:'p440', '{registers}', '[]'), '22023', 'no registers'),
  (jsonb_set(jsonb_set(:'p440', '{version}', '3'), '{profile}', '"Elite 440"'), '23514',
   'a profile name that is not an identifier'),
  (pg_temp.entry(jsonb_set(:'p440', '{version}', '3'), 0, 'decimals', '3'), '23514',
   'a float register with decimals'),
  (pg_temp.entry(pg_temp.entry(jsonb_set(:'p440', '{version}', '3'), 0, 'type', '"u32"'), 0,
                 'decimals', NULL), '23514', 'an integer register without decimals'),
  (pg_temp.entry(pg_temp.entry(jsonb_set(:'p440', '{version}', '3'), 0, 'type', '"u32"'), 0,
                 'decimals', '10'), '23514', 'decimals above 9'),
  (pg_temp.entry(jsonb_set(:'p440', '{version}', '3'), 0, 'kind', '"net"'), '22P02',
   'an unknown kind'),
  (pg_temp.entry(jsonb_set(:'p440', '{version}', '3'), 0, 'unit', '"MWh"'), '22P02',
   'an unknown unit'),
  (pg_temp.entry(jsonb_set(:'p440', '{version}', '3'), 0, 'unit', NULL), '23502', 'no unit'),
  (pg_temp.entry(jsonb_set(:'p440', '{version}', '3'), 0, 'address', '65536'), '23514',
   'an address above 65535'),
  (jsonb_set(jsonb_set(:'p440', '{version}', '3'), '{registers,1}',
             :'p440'::jsonb -> 'registers' -> 0), '23505', 'a register key given twice')
) c (d, state, what);

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s', profile, version), ', ' ORDER BY profile, version)
   FROM store.profile_versions),
  'elite_440 1, elite_440 2, elite_500 1',
  'and nothing of a refused file is loaded');

SELECT pg_temp.is(pg_temp.sqlstate_as('postgres', q), 'P0001', 'the owner is refused: ' || q)
FROM unnest(ARRAY[
  $q$UPDATE store.profile_versions SET loaded_at = now()$q$,
  'DELETE FROM store.profile_versions',
  'SET LOCAL client_min_messages = warning; TRUNCATE store.profile_versions CASCADE',
  $q$UPDATE store.profile_registers SET unit = 'Wh'$q$,
  $q$UPDATE store.profile_registers SET kind = 'interval'$q$,
  'DELETE FROM store.profile_registers',
  'SET LOCAL client_min_messages = warning; TRUNCATE store.profile_registers CASCADE'
]) q;

ROLLBACK;
