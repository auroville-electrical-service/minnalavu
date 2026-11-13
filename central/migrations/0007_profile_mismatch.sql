-- migrate:up

-- Reason for each register of a meter whose product code or energy unit setting
-- is not its profile's (contract/schema/batch.v1.schema.json).
ALTER TYPE store.missed_reason ADD VALUE 'profile_mismatch';

-- migrate:down
-- Forward only: an enum value cannot be dropped while rows may use it.
