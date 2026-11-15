-- migrate:up

-- A registry serial is one the polling config can carry
-- (contract/config/config.v1.schema.json): printable ASCII without
-- surrounding spaces, as a meter's serial is read.
-- contract: central/test/config.sql
ALTER TABLE registry.meters DROP CONSTRAINT meters_serial_check;
ALTER TABLE registry.meters ADD CONSTRAINT meters_serial_check
  CHECK (serial ~ '^[!-~]([ -~]*[!-~])?$' AND length(serial) <= 100);

-- migrate:down
-- Forward only. Undo with a new migration.
