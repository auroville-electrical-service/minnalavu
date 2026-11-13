-- migrate:up

-- The names the batch schema allows (contract/schema/batch.v1.schema.json);
-- the ingest checks read these lists.
CREATE TYPE store.clock_source AS ENUM ('ntp', 'rtc', 'unsynced');
CREATE TYPE store.reading_unit AS ENUM ('Wh', 'kWh', 'varh', 'kvarh');
CREATE TYPE store.missed_reason AS ENUM (
  'timeout', 'closed', 'exception', 'invalid_request', 'unexpected_response',
  'malformed_response', 'bad_crc', 'malformed_frame', 'socket', 'unreachable', 'decode'
);

CREATE TABLE store.collectors (
  id text PRIMARY KEY CHECK (id ~ '^[a-z][a-z0-9_]{0,39}$'),
  role name NOT NULL UNIQUE GENERATED ALWAYS AS (('collector_' || id)::name) STORED,
  created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE store.collectors IS
  'One row per collector. Its token names role; the ingest function finds the caller by it.';

-- A batch as first received. A resent batch adds an upload, not a batch.
CREATE TABLE store.batches (
  batch_id uuid PRIMARY KEY,
  collector_id text NOT NULL REFERENCES store.collectors (id),
  received_at timestamptz NOT NULL,
  clock_source store.clock_source NOT NULL,
  clock_last_sync_at timestamptz,
  readings integer NOT NULL CHECK (readings >= 0),
  missed_reads integer NOT NULL CHECK (missed_reads >= 0)
);
COMMENT ON COLUMN store.batches.clock_source IS
  'The collector''s clock status when every event in the batch was recorded.';
CREATE INDEX ON store.batches (collector_id, received_at DESC);

-- Every time a batch arrives, the first time and each resend, with the
-- collector's backlog as it reported it then.
CREATE TABLE store.uploads (
  upload_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  batch_id uuid NOT NULL REFERENCES store.batches (batch_id),
  collector_id text NOT NULL REFERENCES store.collectors (id),
  received_at timestamptz NOT NULL,
  sent_at timestamptz NOT NULL,
  backlog_events bigint NOT NULL,
  backlog_bytes bigint NOT NULL,
  backlog_batches bigint NOT NULL,
  backlog_oldest timestamptz,
  backlog_max_bytes bigint NOT NULL,
  backlog_refused bigint NOT NULL,
  backlog_discarded_files bigint NOT NULL,
  backlog_quarantined bigint NOT NULL,
  readings_inserted integer NOT NULL,
  readings_duplicate integer NOT NULL,
  readings_conflicting integer NOT NULL,
  missed_reads_inserted integer NOT NULL,
  missed_reads_duplicate integer NOT NULL
);
COMMENT ON COLUMN store.uploads.sent_at IS
  'The collector''s clock at sending; against received_at it shows clock drift.';
CREATE INDEX ON store.uploads (collector_id, received_at DESC);

-- Raw readings, exactly as sent.
-- contract: central/test/ingest.sql
CREATE TABLE store.readings (
  meter_serial text NOT NULL,
  register_key text NOT NULL,
  read_at timestamptz NOT NULL,
  value numeric NOT NULL,
  unit store.reading_unit NOT NULL,
  raw_words integer[] NOT NULL,
  profile text NOT NULL,
  endpoint_host text NOT NULL,
  endpoint_port integer NOT NULL,
  unit_id smallint NOT NULL,
  collector_id text NOT NULL REFERENCES store.collectors (id),
  batch_id uuid NOT NULL REFERENCES store.batches (batch_id),
  CONSTRAINT readings_key UNIQUE (meter_serial, register_key, read_at)
);
COMMENT ON COLUMN store.readings.read_at IS
  'The collector''s clock when the reply arrived; see the batch''s clock_source.';
SELECT create_hypertable('store.readings', by_range('read_at', INTERVAL '7 days'));

-- A reading whose key is taken by a reading with other content.
-- contract: central/test/ingest.sql
CREATE TABLE store.reading_conflicts (
  LIKE store.readings,
  received_at timestamptz NOT NULL,
  PRIMARY KEY (batch_id, meter_serial, register_key, read_at),
  FOREIGN KEY (collector_id) REFERENCES store.collectors (id),
  FOREIGN KEY (batch_id) REFERENCES store.batches (batch_id)
);

-- Reads that were due and did not happen, for the health views.
CREATE TABLE store.missed_reads (
  meter_serial text NOT NULL,
  register_key text NOT NULL,
  read_at timestamptz NOT NULL,
  reason store.missed_reason NOT NULL,
  exception_code smallint CHECK (exception_code BETWEEN 1 AND 255),
  detail text CHECK (length(detail) <= 200),
  attempts integer NOT NULL CHECK (attempts >= 0),
  raw_words integer[],
  profile text NOT NULL,
  endpoint_host text NOT NULL,
  endpoint_port integer NOT NULL,
  unit_id smallint NOT NULL,
  collector_id text NOT NULL REFERENCES store.collectors (id),
  batch_id uuid NOT NULL REFERENCES store.batches (batch_id),
  CONSTRAINT missed_reads_key UNIQUE (meter_serial, register_key, read_at)
);
COMMENT ON COLUMN store.missed_reads.read_at IS 'When the read was due and given up on.';
SELECT create_hypertable('store.missed_reads', by_range('read_at', INTERVAL '7 days'));

-- contract: central/test/ingest.sql
CREATE FUNCTION store.refuse_change() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '% on %.% refused: raw data is never changed or deleted',
    TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME
    USING HINT = 'Corrections are separate records that reference the raw data.';
END
$$;

DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['readings', 'reading_conflicts', 'missed_reads', 'batches', 'uploads'] LOOP
    EXECUTE format(
      'CREATE TRIGGER refuse_change BEFORE UPDATE OR DELETE ON store.%I
         FOR EACH ROW EXECUTE FUNCTION store.refuse_change()', t);
    EXECUTE format(
      'CREATE TRIGGER refuse_truncate BEFORE TRUNCATE ON store.%I
         FOR EACH STATEMENT EXECUTE FUNCTION store.refuse_change()', t);
  END LOOP;
END
$$;

-- migrate:down
-- Forward only: a rollback would drop raw data. Undo with a new migration.
