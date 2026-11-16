-- migrate:up

-- The stored quantities of each profile version: what a copied history,
-- snapshot or load-survey entry is, by store and register key, with its
-- decode, unit and kind. A history or snapshot quantity has its own address;
-- a load-survey quantity is a parameter number, read through the day's
-- values register (whose table and decode the row carries, without its
-- address). Only a cumulative quantity may be differenced as energy, so the
-- load survey (energy per interval) never holds one, and no other store holds
-- an interval quantity.

CREATE TYPE store.stored_store AS ENUM ('history', 'snapshot', 'load_survey');
CREATE TYPE store.stored_unit AS ENUM ('Wh', 'kWh', 'varh', 'kvarh', 'V', 'A', 'Hz');

-- contract: central/test/profiles.sql
CREATE TABLE store.profile_stored (
  profile text NOT NULL,
  version bigint NOT NULL,
  store store.stored_store NOT NULL,
  register_key text NOT NULL CHECK (register_key <> ''),
  register_table store.register_table NOT NULL,
  address integer CHECK (address BETWEEN 0 AND 65535),
  parameter integer CHECK (parameter BETWEEN 0 AND 65535),
  type store.register_type NOT NULL CHECK (type IN ('f32', 'f64')),
  word_order store.word_order NOT NULL,
  unit store.stored_unit NOT NULL,
  kind store.register_kind NOT NULL,
  PRIMARY KEY (profile, version, store, register_key),
  UNIQUE (profile, version, store, parameter),
  FOREIGN KEY (profile, version) REFERENCES store.profile_versions (profile, version),
  CONSTRAINT profile_stored_place CHECK (
    (store = 'load_survey') = (parameter IS NOT NULL)
    AND (address IS NULL) = (parameter IS NOT NULL)),
  CONSTRAINT profile_stored_no_cumulative_load_survey CHECK (
    NOT (store = 'load_survey' AND kind = 'cumulative')),
  CONSTRAINT profile_stored_interval_only_in_load_survey CHECK (
    NOT (store <> 'load_survey' AND kind = 'interval'))
);
COMMENT ON TABLE store.profile_stored IS
  'Each profile version''s stored quantities, loaded from contract/profiles by bin/load-profiles; never changed.';
COMMENT ON COLUMN store.profile_stored.parameter IS
  'Load survey only: the parameter number the selector is set to; its values are read at the section''s values register.';

CREATE TRIGGER refuse_change BEFORE UPDATE OR DELETE ON store.profile_stored
  FOR EACH ROW EXECUTE FUNCTION store.refuse_change();
CREATE TRIGGER refuse_truncate BEFORE TRUNCATE ON store.profile_stored
  FOR EACH STATEMENT EXECUTE FUNCTION store.refuse_change();

-- A profile file's stored quantities as catalog rows, at its version; none
-- for a file with no stored section.
CREATE FUNCTION store.profile_document_stored(document jsonb, version bigint)
RETURNS SETOF store.profile_stored
LANGUAGE sql IMMUTABLE AS $$
  SELECT document ->> 'profile', version, s.key::store.stored_store, r ->> 'key',
         (r ->> 'table')::store.register_table, (r ->> 'address')::integer, NULL::integer,
         (r ->> 'type')::store.register_type, (r ->> 'word_order')::store.word_order,
         (r ->> 'unit')::store.stored_unit, (r ->> 'kind')::store.register_kind
  FROM jsonb_each(coalesce(document -> 'stored', '{}')) s
  CROSS JOIN LATERAL jsonb_array_elements(
    CASE WHEN s.key = 'load_survey' THEN '[]' ELSE s.value -> 'registers' END) r
  UNION ALL
  SELECT document ->> 'profile', version, 'load_survey', p ->> 'key',
         (v ->> 'table')::store.register_table, NULL::integer, (p ->> 'number')::integer,
         (v ->> 'type')::store.register_type, (v ->> 'word_order')::store.word_order,
         (p ->> 'unit')::store.stored_unit, (p ->> 'kind')::store.register_kind
  FROM (SELECT document -> 'stored' -> 'load_survey' AS ls) l
  CROSS JOIN LATERAL (SELECT l.ls -> 'values' AS v) values_register
  CROSS JOIN LATERAL jsonb_array_elements(l.ls -> 'parameters') p
$$;

-- Load one profile file's version into the catalog, as the owner: its
-- registers, and its stored quantities where it has a stored section. A
-- version already loaded is left as it is when the file names the same
-- registers and stored quantities with the same decode, table, address or
-- parameter, unit and kind, and refused (22023) otherwise. A stored section
-- must list a quantity in each store it names. Returns 'new' or 'already
-- loaded'. Run by bin/load-profiles.
-- contract: central/test/profiles.sql
CREATE OR REPLACE FUNCTION admin.load_profile(document jsonb) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
  p text := document ->> 'profile';
  v bigint;
  empty_store text;
  differing text;
BEGIN
  IF jsonb_typeof(document -> 'version') IS DISTINCT FROM 'number'
     OR (document -> 'version')::numeric <> trunc((document -> 'version')::numeric) THEN
    RAISE SQLSTATE '22023' USING MESSAGE = format('profile %s: version must be an integer', p);
  END IF;
  IF jsonb_typeof(document -> 'registers') IS DISTINCT FROM 'array'
     OR jsonb_array_length(document -> 'registers') = 0 THEN
    RAISE SQLSTATE '22023' USING MESSAGE = format('profile %s: registers must be a non-empty list', p);
  END IF;
  IF document ? 'stored' THEN
    SELECT string_agg(s.key, ', ' ORDER BY s.key) INTO empty_store
    FROM jsonb_each(document -> 'stored') s
    WHERE coalesce(jsonb_array_length(CASE WHEN jsonb_typeof(
            s.value -> CASE WHEN s.key = 'load_survey' THEN 'parameters' ELSE 'registers' END)
            = 'array' THEN s.value -> CASE WHEN s.key = 'load_survey' THEN 'parameters'
                                         ELSE 'registers' END END), 0) = 0;
    IF empty_store IS NOT NULL THEN
      RAISE SQLSTATE '22023' USING
        MESSAGE = format('profile %s: stored %s must list its quantities', p, empty_store);
    END IF;
  END IF;
  v := (document -> 'version')::numeric;

  IF NOT EXISTS (SELECT FROM store.profile_versions WHERE profile = p AND version = v) THEN
    INSERT INTO store.profile_versions (profile, version) VALUES (p, v);
    INSERT INTO store.profile_registers SELECT * FROM store.profile_document_registers(document, v);
    INSERT INTO store.profile_stored SELECT * FROM store.profile_document_stored(document, v);
    RETURN 'new';
  END IF;

  WITH loading AS (
    SELECT * FROM store.profile_document_registers(document, v)
  ), loaded AS (
    SELECT * FROM store.profile_registers r WHERE r.profile = p AND r.version = v
  ), loading_stored AS (
    SELECT * FROM store.profile_document_stored(document, v)
  ), loaded_stored AS (
    SELECT * FROM store.profile_stored s WHERE s.profile = p AND s.version = v
  )
  SELECT string_agg(DISTINCT d.key, ', ') INTO differing
  FROM ((SELECT coalesce(register_key, '(no key)') AS key
         FROM ((SELECT * FROM loading EXCEPT ALL SELECT * FROM loaded)
               UNION ALL
               (SELECT * FROM loaded EXCEPT ALL SELECT * FROM loading)) r)
        UNION ALL
        (SELECT format('%s %s', store, coalesce(register_key, '(no key)'))
         FROM ((SELECT * FROM loading_stored EXCEPT ALL SELECT * FROM loaded_stored)
               UNION ALL
               (SELECT * FROM loaded_stored EXCEPT ALL SELECT * FROM loading_stored)) s)) d;
  IF differing IS NOT NULL THEN
    RAISE SQLSTATE '22023' USING
      MESSAGE = format('profile %s version %s is already loaded with other registers: %s',
                       p, v, differing),
      HINT = 'A loaded version never changes: give the profile a new version.';
  END IF;
  RETURN 'already loaded';
END
$$;

-- migrate:down
-- Forward only: a rollback would drop the catalog. Undo with a new migration.
