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

-- A profile file's stored quantities as 'store key table address-or-#parameter
-- type word_order unit kind': history, snapshot, then the load survey, each in
-- the file's order (by address, and by parameter number).
CREATE FUNCTION pg_temp.file_stored(document jsonb) RETURNS text
LANGUAGE sql AS $$
  SELECT string_agg(line, '; ' ORDER BY o, i)
  FROM (
    SELECT o, i, format('%s %s %s %s %s %s %s %s', s, r ->> 'key', r ->> 'table', r ->> 'address',
                        r ->> 'type', r ->> 'word_order', r ->> 'unit', r ->> 'kind') AS line
    FROM (VALUES (1, 'history'), (2, 'snapshot')) st (o, s)
    CROSS JOIN LATERAL jsonb_array_elements(document -> 'stored' -> s -> 'registers')
      WITH ORDINALITY e (r, i)
    UNION ALL
    SELECT 3, i, format('load_survey %s %s #%s %s %s %s %s', p ->> 'key', v ->> 'table',
                        p ->> 'number', v ->> 'type', v ->> 'word_order', p ->> 'unit',
                        p ->> 'kind')
    FROM (SELECT document -> 'stored' -> 'load_survey' -> 'values' AS v) values_register
    CROSS JOIN LATERAL jsonb_array_elements(document -> 'stored' -> 'load_survey' -> 'parameters')
      WITH ORDINALITY e (p, i)
  ) f
$$;

CREATE FUNCTION pg_temp.catalog_stored(p text, v bigint) RETURNS text
LANGUAGE sql AS $$
  SELECT string_agg(format('%s %s %s %s %s %s %s %s', store, register_key, register_table,
                           coalesce(address::text, '#' || parameter), type, word_order, unit,
                           kind), '; '
                    ORDER BY store, address, parameter)
  FROM store.profile_stored WHERE profile = p AND version = v
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

-- A document with one stored quantity changed: entry i of a history's or
-- snapshot's registers, or of the load survey's parameters.
CREATE FUNCTION pg_temp.stored(document jsonb, store text, i integer, field text, value jsonb)
RETURNS jsonb
LANGUAGE sql AS $$
  SELECT jsonb_set(document,
    ARRAY['stored', store, CASE WHEN store = 'load_survey' THEN 'parameters' ELSE 'registers' END,
          i::text, field],
    value)
$$;

-- The file's version, and a document at the file's version plus n: one not loaded.
CREATE FUNCTION pg_temp.v(document jsonb) RETURNS bigint
LANGUAGE sql AS $$ SELECT (document ->> 'version')::bigint $$;

CREATE FUNCTION pg_temp.later(document jsonb, n integer) RETURNS jsonb
LANGUAGE sql AS $$ SELECT jsonb_set(document, '{version}', to_jsonb(pg_temp.v(document) + n)) $$;

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s', profile, version), ', ' ORDER BY profile, version)
   FROM store.profile_versions),
  format('elite_440 %s, elite_500 %s', :'p440'::jsonb -> 'version', :'p500'::jsonb -> 'version'),
  'every profile in contract/profiles is loaded, at the version its file names');

SELECT pg_temp.is(pg_temp.catalog_registers(d ->> 'profile', pg_temp.v(d)),
                  pg_temp.file_registers(d),
                  'the catalog holds every register of ' || (d ->> 'profile') || ' as its file gives it')
FROM (VALUES (:'p440'::jsonb), (:'p500'::jsonb)) f (d);

SELECT pg_temp.is(pg_temp.catalog_stored(d ->> 'profile', pg_temp.v(d)),
                  pg_temp.file_stored(d),
                  'and every stored quantity of ' || (d ->> 'profile') || ' as its file gives it')
FROM (VALUES (:'p440'::jsonb), (:'p500'::jsonb)) f (d);

SELECT pg_temp.is(
  (SELECT string_agg(DISTINCT format('%s %s', type, coalesce(decimals::text, '-')), ', ')
   FROM store.profile_registers WHERE type IN ('f32', 'f64')),
  'f32 -, f64 -',
  'a float register has no decimals');

SELECT pg_temp.is(
  (SELECT string_agg(DISTINCT format('%s %s', store, kind), ', ')
   FROM store.profile_stored),
  'history cumulative, load_survey instantaneous, load_survey interval, snapshot cumulative',
  'the profiles'' histories and snapshots are cumulative; their load surveys interval energy '
  || 'and instantaneous values');

SELECT pg_temp.is(
  (SELECT count(*) FROM store.profile_stored
   WHERE profile = 'elite_500' AND store = 'load_survey' AND parameter = 6),
  0::bigint,
  'the 500''s net active load-survey parameter is in no version');

SELECT pg_temp.is(pg_temp.load(:'p440'), 'already loaded',
                  'loading a version again with the same registers changes nothing');

SELECT pg_temp.is(pg_temp.load(d), 'already loaded',
  'nor does a change to what the catalog does not hold: ' || what)
FROM (VALUES
  (pg_temp.entry(:'p440', 0, 'verified_on_device', '"2026-11-20"'), 'the date an entry was verified'),
  (pg_temp.stored(:'p440', 'history', 0, 'verified_on_device', '"2026-11-20"'),
   'the date a stored entry was verified'),
  (jsonb_set(:'p440', '{stored,load_survey,values,per_request}', '24'),
   'how many intervals are read at once')
) c (d, what);

SELECT pg_temp.is(pg_temp.load(d),
  format('22023: profile elite_440 version %s is already loaded with other registers: %s',
         pg_temp.v(:'p440'), keys),
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
                 '"reactive_energy_import"'), 'reactive_energy_import', 'a register added'),
  (pg_temp.stored(:'p440', 'history', 0, 'address', '600'), 'history active_energy_import',
   'a stored address'),
  (pg_temp.stored(:'p440', 'snapshot', 1, 'unit', '"Wh"'), 'snapshot active_energy_export',
   'a stored unit'),
  (pg_temp.stored(:'p440', 'load_survey', 0, 'kind', '"demand"'),
   'load_survey active_energy_import', 'a stored kind'),
  (pg_temp.stored(:'p440', 'load_survey', 0, 'number', '2'),
   'load_survey active_energy_import', 'a parameter number'),
  (jsonb_set(:'p440', '{stored,load_survey,values,word_order}', '"high_first"'),
   (SELECT string_agg('load_survey ' || (p ->> 'key'), ', ' ORDER BY p ->> 'key')
    FROM jsonb_array_elements(:'p440'::jsonb -> 'stored' -> 'load_survey' -> 'parameters') p),
   'the load survey''s values decode'),
  (jsonb_set(:'p440', '{stored,snapshot,registers}',
             (:'p440'::jsonb -> 'stored' -> 'snapshot' -> 'registers') - 0),
   'snapshot active_energy_import', 'a stored quantity dropped'),
  (:'p440'::jsonb - 'stored',
   (SELECT string_agg(k, ', ' ORDER BY k) FROM (
      SELECT DISTINCT format('%s %s', store, register_key) AS k FROM store.profile_stored
      WHERE profile = 'elite_440' AND version = pg_temp.v(:'p440')) s),
   'the stored section dropped')
) c (d, keys, what);

SELECT pg_temp.is(pg_temp.catalog_registers('elite_440', pg_temp.v(:'p440')),
                  pg_temp.file_registers(:'p440'),
                  'and the loaded version is as it was');

SELECT pg_temp.is(
  pg_temp.load(pg_temp.stored(pg_temp.entry(pg_temp.later(:'p440', 1), 0, 'kind', '"interval"'),
                              'history', 0, 'unit', '"Wh"')),
  'new',
  'a correction loads as a new version');

SELECT pg_temp.is(
  format('%s / %s / %s / %s', pg_temp.catalog_registers('elite_440', pg_temp.v(:'p440')),
         pg_temp.catalog_registers('elite_440', pg_temp.v(:'p440') + 1),
         pg_temp.catalog_stored('elite_440', pg_temp.v(:'p440')),
         pg_temp.catalog_stored('elite_440', pg_temp.v(:'p440') + 1)),
  format('%s / %s / %s / %s', pg_temp.file_registers(:'p440'),
         pg_temp.file_registers(pg_temp.entry(:'p440', 0, 'kind', '"interval"')),
         pg_temp.file_stored(:'p440'),
         pg_temp.file_stored(pg_temp.stored(:'p440', 'history', 0, 'unit', '"Wh"'))),
  'and the old version stays as it was beside it');

SELECT pg_temp.is(pg_temp.load(pg_temp.later(:'p500', 1) - 'stored'), 'new',
                  'a profile with no stored section loads');

SELECT pg_temp.is(
  (SELECT count(*) FROM store.profile_stored
   WHERE profile = 'elite_500' AND version = pg_temp.v(:'p500') + 1),
  0::bigint,
  'with no stored quantities');

-- The kind rules: only a cumulative quantity may be
-- differenced as energy, and energy per interval is never one.
SELECT pg_temp.is(pg_temp.load(d), '23514: new row for relation "profile_stored" violates check '
                  || 'constraint "' || con || '"',
                  'the catalog refuses ' || what)
FROM (VALUES
  (pg_temp.stored(pg_temp.later(:'p440', 2), 'load_survey', 0, 'kind', '"cumulative"'),
   'profile_stored_no_cumulative_load_survey', 'a cumulative quantity in the load survey'),
  (pg_temp.stored(pg_temp.later(:'p440', 2), 'history', 0, 'kind', '"interval"'),
   'profile_stored_interval_only_in_load_survey', 'an interval quantity in a history'),
  (pg_temp.stored(pg_temp.later(:'p500', 2), 'snapshot', 0, 'kind', '"interval"'),
   'profile_stored_interval_only_in_load_survey', 'an interval quantity in a snapshot')
) c (d, con, what);

SELECT pg_temp.is(
  pg_temp.load(pg_temp.stored(pg_temp.stored(pg_temp.later(:'p440', 2), 'history', 0, 'kind',
                                             '"demand"'),
                              'load_survey', 0, 'kind', '"demand"')),
  'new',
  'and accepts a demand quantity in a history and in the load survey');

SELECT pg_temp.ok(pg_temp.load(d) LIKE state || ': %', 'a profile file is refused: ' || what)
FROM (VALUES
  (jsonb_set(:'p440', '{version}', '0'), '23514', 'version 0'),
  (jsonb_set(:'p440', '{version}', '9007199254740992'), '23514', 'a version above 2^53 - 1'),
  (jsonb_set(:'p440', '{version}', '"9"'), '22023', 'a version as a string'),
  (jsonb_set(:'p440', '{version}', '9.5'), '22023', 'a fractional version'),
  (jsonb_set(:'p440', '{registers}', '[]'), '22023', 'no registers'),
  (jsonb_set(pg_temp.later(:'p440', 3), '{profile}', '"Elite 440"'), '23514',
   'a profile name that is not an identifier'),
  (pg_temp.entry(pg_temp.later(:'p440', 3), 0, 'decimals', '3'), '23514',
   'a float register with decimals'),
  (pg_temp.entry(pg_temp.entry(pg_temp.later(:'p440', 3), 0, 'type', '"u32"'), 0,
                 'decimals', NULL), '23514', 'an integer register without decimals'),
  (pg_temp.entry(pg_temp.entry(pg_temp.later(:'p440', 3), 0, 'type', '"u32"'), 0,
                 'decimals', '10'), '23514', 'decimals above 9'),
  (pg_temp.entry(pg_temp.later(:'p440', 3), 0, 'kind', '"net"'), '22P02',
   'an unknown kind'),
  (pg_temp.entry(pg_temp.later(:'p440', 3), 0, 'unit', '"MWh"'), '22P02',
   'an unknown unit'),
  (pg_temp.entry(pg_temp.later(:'p440', 3), 0, 'unit', NULL), '23502', 'no unit'),
  (pg_temp.entry(pg_temp.later(:'p440', 3), 0, 'address', '65536'), '23514',
   'an address above 65535'),
  (jsonb_set(pg_temp.later(:'p440', 3), '{registers,1}',
             :'p440'::jsonb -> 'registers' -> 0), '23505', 'a register key given twice'),
  (pg_temp.stored(pg_temp.later(:'p440', 3), 'history', 0, 'kind', '"net"'), '22P02',
   'an unknown stored kind'),
  (pg_temp.stored(pg_temp.later(:'p440', 3), 'snapshot', 0, 'unit', '"MWh"'), '22P02',
   'an unknown stored unit'),
  (pg_temp.stored(pg_temp.later(:'p440', 3), 'history', 0, 'type', '"u32"'), '23514',
   'an integer stored register'),
  (pg_temp.stored(pg_temp.later(:'p440', 3), 'history', 0, 'address', 'null'), '23514',
   'a history quantity with no address'),
  (pg_temp.stored(pg_temp.later(:'p440', 3), 'load_survey', 0, 'number', 'null'), '23514',
   'a load-survey quantity with no parameter number'),
  (pg_temp.stored(pg_temp.later(:'p440', 3), 'load_survey', 1, 'number', '0'), '23505',
   'a parameter number given twice'),
  (pg_temp.stored(pg_temp.later(:'p440', 3), 'snapshot', 1, 'key', '"active_energy_import"'),
   '23505', 'a stored key given twice in one store'),
  (jsonb_set(pg_temp.later(:'p440', 3), '{stored,tou_history}',
             :'p440'::jsonb -> 'stored' -> 'history'), '22P02', 'a store the catalog does not know'),
  (jsonb_set(pg_temp.later(:'p440', 3), '{stored,history,registers}', '[]'), '22023',
   'a store with no quantities'),
  (jsonb_set(pg_temp.later(:'p440', 3), '{stored,load_survey}',
             (:'p440'::jsonb -> 'stored' -> 'load_survey') - 'parameters'), '22023',
   'a load survey with no parameters')
) c (d, state, what);

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s', profile, version), ', ' ORDER BY profile, version)
   FROM store.profile_versions),
  format('elite_440 %s, elite_440 %s, elite_440 %s, elite_500 %s, elite_500 %s',
         pg_temp.v(:'p440'), pg_temp.v(:'p440') + 1, pg_temp.v(:'p440') + 2,
         pg_temp.v(:'p500'), pg_temp.v(:'p500') + 1),
  'and nothing of a refused file is loaded');

SELECT pg_temp.is(pg_temp.sqlstate_as('postgres', q), 'P0001', 'the owner is refused: ' || q)
FROM unnest(ARRAY[
  $q$UPDATE store.profile_versions SET loaded_at = now()$q$,
  'DELETE FROM store.profile_versions',
  'SET LOCAL client_min_messages = warning; TRUNCATE store.profile_versions CASCADE',
  $q$UPDATE store.profile_registers SET unit = 'Wh'$q$,
  $q$UPDATE store.profile_registers SET kind = 'interval'$q$,
  'DELETE FROM store.profile_registers',
  'SET LOCAL client_min_messages = warning; TRUNCATE store.profile_registers CASCADE',
  $q$UPDATE store.profile_stored SET unit = 'Wh'$q$,
  $q$UPDATE store.profile_stored SET kind = 'demand'$q$,
  'DELETE FROM store.profile_stored',
  'SET LOCAL client_min_messages = warning; TRUNCATE store.profile_stored CASCADE'
]) q;

ROLLBACK;
