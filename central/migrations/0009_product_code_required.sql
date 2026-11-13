-- migrate:up

-- Every reading carries the product code the meter reported. NOT VALID: raw
-- readings are never changed, so rows stored without one stay as they are;
-- every row written from here on must have one.
-- contract: central/test/ingest.sql
ALTER TABLE store.readings
  ADD CONSTRAINT readings_product_code_not_null NOT NULL product_code NOT VALID;
ALTER TABLE store.reading_conflicts
  ADD CONSTRAINT reading_conflicts_product_code_not_null NOT NULL product_code NOT VALID;
COMMENT ON COLUMN store.readings.product_code IS
  'The product code the meter reported in that round; NULL only on rows stored before every reading had to carry one.';

CREATE OR REPLACE FUNCTION store.check_reading(v jsonb, path text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM store.check_object(v, path, ARRAY[
    'endpoint', 'unit_id', 'meter_serial', 'product_code', 'profile', 'register_key',
    'timestamp', 'raw_words', 'value', 'unit']);
  PERFORM store.check_event(v, path);
  PERFORM store.check_string(v -> 'meter_serial', path || '.meter_serial', 2147483647);
  PERFORM store.check_string(v -> 'product_code', path || '.product_code', 2147483647);
  PERFORM store.check_words(v -> 'raw_words', path || '.raw_words', 1, 4);
  PERFORM store.check_match(v -> 'value', path || '.value', '^-?[0-9]+(\.[0-9]+)?$',
    'a decimal string such as "1234.56"');
  PERFORM store.check_enum(v -> 'unit', path || '.unit',
    enum_range(NULL::store.reading_unit)::text[]);
END
$$;

-- migrate:down
-- Forward only: a rollback would drop raw data. Undo with a new migration.
