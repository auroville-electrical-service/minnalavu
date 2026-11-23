-- migrate:up

-- The store's schema as migrations 0001-0038 left it, in one file: a store
-- already at 0038 has nothing pending, and a new one is built from this.
-- Forward only, as before: change it with a new migration, never by editing
-- this one.

-- Roles belong to the cluster: created only if missing, since the SQL tests
-- migrate a second database on it. Logins and their passwords are set outside
-- the migrations (central/README.md); the group roles' logins are members.
-- contract: central/test/grants.sql
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'authenticator') THEN
    CREATE ROLE authenticator NOLOGIN NOINHERIT;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'collector') THEN
    CREATE ROLE collector NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'monitor') THEN
    CREATE ROLE monitor NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'minkanakku_staff') THEN
    CREATE ROLE minkanakku_staff NOLOGIN;
  END IF;
END
$$;

CREATE EXTENSION IF NOT EXISTS timescaledb;

-- Nothing is granted by default: not the public schema, not temporary
-- tables, not EXECUTE on a new function. Every grant below is explicit.
-- contract: central/test/grants.sql
REVOKE ALL ON SCHEMA public FROM PUBLIC;
DO $$
BEGIN
  EXECUTE format('REVOKE TEMPORARY ON DATABASE %I FROM PUBLIC', current_database());
END
$$;
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

-- SQL-language bodies name tables defined further down; each is checked by
-- the SQL tests, which call it.
SET LOCAL check_function_bodies = false;

CREATE SCHEMA store;
COMMENT ON SCHEMA store IS 'The data. No role PostgREST uses has any privilege here.';

CREATE SCHEMA registry;
COMMENT ON SCHEMA registry IS
  'What is installed where, from when. Written only through admin functions, and only by adding rows.';

CREATE SCHEMA jobs;
COMMENT ON SCHEMA jobs IS
  'Requests for jobs a collector runs. minkanakku_staff may call jobs.request_job and read jobs.request_status, and nothing else.';
GRANT USAGE ON SCHEMA jobs TO minkanakku_staff;

CREATE SCHEMA admin;
COMMENT ON SCHEMA admin IS 'Functions for the operator, run as the database owner.';

CREATE SCHEMA api;
COMMENT ON SCHEMA api IS 'What PostgREST exposes (db-schemas = api).';
GRANT USAGE ON SCHEMA api TO collector;

CREATE SCHEMA health;
COMMENT ON SCHEMA health IS
  'Views of collection health. The role monitor may read them and nothing else.';
GRANT USAGE ON SCHEMA health TO monitor;

-- ==== store =================================================================

-- How a clock check ended, as batch.v1 names it. The names the batch schema
-- allows (contract/schema/batch.v1.schema.json); the ingest checks read them.
CREATE TYPE store.clock_check_outcome AS ENUM (
    'answered',
    'timeout',
    'unreachable',
    'kiss_of_death',
    'invalid'
);

-- What started a clock check: the collector's start, its daily check, or a
-- step in its clock. The names the batch schema allows.
CREATE TYPE store.clock_check_trigger AS ENUM (
    'start',
    'daily',
    'step'
);

-- What the collector's OS claimed of its clock when a batch's events were
-- recorded: shown beside the measured checks, never judged by. The names the
-- batch schema allows.
CREATE TYPE store.clock_source AS ENUM (
    'ntp',
    'rtc',
    'unsynced'
);

-- Why a due read gave no reading, as batch.v1 names it. decode and
-- profile_mismatch are the meter's answer, not the read failing
-- (health.endpoints). A reason is added with ALTER TYPE ... ADD VALUE: stored
-- rows hold these values.
CREATE TYPE store.missed_reason AS ENUM (
    'timeout',
    'closed',
    'exception',
    'invalid_request',
    'unexpected_response',
    'malformed_response',
    'bad_crc',
    'malformed_frame',
    'socket',
    'unreachable',
    'decode',
    'profile_mismatch'
);

-- A reading's unit, as its profile version fixes it: kept in the catalog, not
-- on each reading. The names contract/profiles allows.
CREATE TYPE store.reading_unit AS ENUM (
    'Wh',
    'kWh',
    'varh',
    'kvarh'
);

-- What a register holds, as its profile names it. Billing takes end − start
-- readings of cumulative registers only, never integrated power.
CREATE TYPE store.register_kind AS ENUM (
    'cumulative',
    'interval',
    'demand',
    'instantaneous'
);

-- Holding (function code 03) or input (04) register, as its profile names it.
CREATE TYPE store.register_table AS ENUM (
    'holding',
    'input'
);

-- A register's width and encoding, as its profile names it: an integer is
-- decoded as raw ÷ 10^decimals, a float as the shortest decimal that round-trips
-- at its width (store.profile_registers).
CREATE TYPE store.register_type AS ENUM (
    'u16',
    'i16',
    'u32',
    'i32',
    'u64',
    'f32',
    'f64'
);

-- The stores a meter keeps and a collector copies: monthly history, daily
-- snapshot, and load survey.
CREATE TYPE store.stored_store AS ENUM (
    'history',
    'snapshot',
    'load_survey'
);

-- A stored quantity's unit, as its profile version fixes it. The names
-- contract/profiles allows.
CREATE TYPE store.stored_unit AS ENUM (
    'Wh',
    'kWh',
    'varh',
    'kvarh',
    'VAh',
    'kVAh',
    'V',
    'A',
    'Hz'
);

-- Which 16-bit word of a wider register comes first, as its profile names it.
CREATE TYPE store.word_order AS ENUM (
    'high_first',
    'low_first'
);

CREATE TABLE store.collectors (
  id text PRIMARY KEY CHECK (id ~ '^[a-z][a-z0-9_]{0,39}$'),
  role name NOT NULL UNIQUE GENERATED ALWAYS AS (('collector_' || id)::name) STORED,
  created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE store.collectors IS 'One row per collector. Its token names role; the ingest function finds the caller by it.';

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

COMMENT ON COLUMN store.batches.clock_source IS 'The collector''s clock status when every event in the batch was recorded.';

CREATE INDEX batches_collector_id_received_at_idx ON store.batches USING btree (collector_id, received_at DESC);

CREATE INDEX batches_received_at_idx ON store.batches USING btree (received_at);

-- Every time a batch arrives, the first time and each resend, with the
-- collector's backlog as it reported it then.
CREATE TABLE store.uploads (
    upload_id bigint NOT NULL,
    batch_id uuid NOT NULL,
    collector_id text NOT NULL,
    received_at timestamp with time zone NOT NULL,
    sent_at timestamp with time zone NOT NULL,
    backlog_events bigint NOT NULL,
    backlog_bytes bigint NOT NULL,
    backlog_batches bigint NOT NULL,
    backlog_oldest timestamp with time zone,
    backlog_max_bytes bigint NOT NULL,
    backlog_refused bigint NOT NULL,
    backlog_discarded_files bigint NOT NULL,
    backlog_quarantined bigint NOT NULL,
    readings_inserted integer NOT NULL,
    readings_duplicate integer NOT NULL,
    readings_conflicting integer NOT NULL,
    missed_reads_inserted integer NOT NULL,
    missed_reads_duplicate integer NOT NULL,
    config_digest text,
    config_refused_digest text,
    config_refusal_reason text,
    stored_entries_inserted integer NOT NULL,
    stored_entries_duplicate integer NOT NULL,
    stored_entries_conflicting integer NOT NULL,
    meter_clock_reads_inserted integer NOT NULL,
    meter_clock_reads_duplicate integer NOT NULL,
    meter_clock_reads_conflicting integer NOT NULL,
    CONSTRAINT config_refused_beside_applied CHECK (((config_refused_digest IS NULL) OR (config_digest IS NOT NULL))),
    CONSTRAINT config_refused_with_reason CHECK (((config_refused_digest IS NULL) = (config_refusal_reason IS NULL))),
    CONSTRAINT uploads_config_digest_check CHECK ((config_digest ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT uploads_config_refusal_reason_check CHECK (((length(config_refusal_reason) >= 1) AND (length(config_refusal_reason) <= 1000))),
    CONSTRAINT uploads_config_refused_digest_check CHECK ((config_refused_digest ~ '^[0-9a-f]{64}$'::text))
);

COMMENT ON COLUMN store.uploads.sent_at IS 'The collector''s clock at sending; against received_at it shows clock drift.';

COMMENT ON COLUMN store.uploads.config_digest IS 'The digest of the polling config the collector was applying (contract/fixtures/config.v1.digests.json).';

COMMENT ON COLUMN store.uploads.config_refused_digest IS 'The digest of a served config the collector refused, with config_refusal_reason; NULL when it reported none.';

ALTER TABLE store.uploads ALTER COLUMN upload_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME store.uploads_upload_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE ONLY store.uploads
    ADD CONSTRAINT uploads_pkey PRIMARY KEY (upload_id);

CREATE INDEX uploads_collector_id_received_at_idx ON store.uploads USING btree (collector_id, received_at DESC);

ALTER TABLE ONLY store.uploads
    ADD CONSTRAINT uploads_batch_id_fkey FOREIGN KEY (batch_id) REFERENCES store.batches(batch_id);

ALTER TABLE ONLY store.uploads
    ADD CONSTRAINT uploads_collector_id_fkey FOREIGN KEY (collector_id) REFERENCES store.collectors(id);

-- The software and firmware names a meter reported, as read. The collector
-- sends a record when the names differ from the last it sent for an address,
-- and the first after it starts, so consecutive records may be identical.
-- Keyed on where and when they were read, as missed reads are: a host and
-- port are unique only per collector (registry.check_history). A name is NULL
-- when the meter did not give it.
-- contract: central/test/ingest.sql
CREATE TABLE store.firmware_reads (
  meter_serial text NOT NULL,
  product_code text NOT NULL,
  read_at timestamptz NOT NULL,
  software text,
  firmware_1 text,
  firmware_2 text,
  modbus_version text,
  endpoint_host text NOT NULL,
  endpoint_port integer NOT NULL,
  unit_id smallint NOT NULL,
  collector_id text NOT NULL REFERENCES store.collectors (id),
  batch_id uuid NOT NULL REFERENCES store.batches (batch_id),
  CONSTRAINT firmware_reads_key
    UNIQUE (collector_id, endpoint_host, endpoint_port, unit_id, read_at)
);

COMMENT ON COLUMN store.firmware_reads.meter_serial IS 'The serial the meter reported in the round the names were read in.';

COMMENT ON COLUMN store.firmware_reads.read_at IS 'The collector''s clock when the names were read; see the batch''s clock_source.';

CREATE INDEX firmware_reads_meter_serial_read_at_idx ON store.firmware_reads USING btree (meter_serial, read_at DESC);

-- Rows are added only by admin.load_profile, and no row is ever changed:
-- every reading names the version it was decoded under.
-- contract: central/test/profiles.sql
CREATE TABLE store.profile_versions (
  profile text NOT NULL CHECK (profile ~ '^[a-z][a-z0-9_]{0,39}$'),
  version bigint NOT NULL CHECK (version BETWEEN 1 AND 9007199254740991),
  loaded_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (profile, version)
);

COMMENT ON TABLE store.profile_versions IS 'Each profile version loaded from contract/profiles by bin/load-profiles. A version never changes; a correction is a new version.';

-- The registers a profile version reads, with each one's decode, from its
-- profile file. Immutable with its version: a correction is a new version.
-- contract: central/test/profiles.sql
CREATE TABLE store.profile_registers (
  profile text NOT NULL,
  version bigint NOT NULL,
  register_key text NOT NULL CHECK (register_key <> ''),
  register_table store.register_table NOT NULL,
  address integer NOT NULL CHECK (address BETWEEN 0 AND 65535),
  type store.register_type NOT NULL,
  word_order store.word_order NOT NULL,
  decimals smallint CHECK (decimals BETWEEN 0 AND 9),
  unit store.reading_unit NOT NULL,
  kind store.register_kind NOT NULL,
  PRIMARY KEY (profile, version, register_key),
  FOREIGN KEY (profile, version) REFERENCES store.profile_versions (profile, version),
  CONSTRAINT profile_registers_decimals
    CHECK ((type IN ('f32', 'f64')) = (decimals IS NULL))
);

COMMENT ON COLUMN store.profile_registers.decimals IS 'An integer register''s value is raw ÷ 10^decimals; a float register has none.';

-- Raw readings, exactly as sent, each under the profile version it was decoded
-- by. Keyed on (meter_serial, register_key, read_at): a resent reading is a
-- duplicate, and one that says otherwise is kept in store.reading_conflicts.
-- Never changed or deleted (refuse_change); corrections are separate records.
-- contract: central/test/ingest.sql
CREATE TABLE store.readings (
    meter_serial text NOT NULL,
    register_key text NOT NULL,
    read_at timestamp with time zone NOT NULL,
    value numeric NOT NULL,
    profile text NOT NULL,
    endpoint_host text NOT NULL,
    endpoint_port integer NOT NULL,
    unit_id smallint NOT NULL,
    collector_id text NOT NULL,
    batch_id uuid NOT NULL,
    product_code text,
    profile_version bigint NOT NULL
);

-- Without TimescaleDB's index on the time column alone: nothing reads by it,
-- and timed at 1,500 meters (9.7M readings) no health view needs it.
SELECT create_hypertable('store.readings', by_range('read_at', INTERVAL '7 days'), create_default_indexes => false);

COMMENT ON COLUMN store.readings.meter_serial IS 'The serial the meter reported in the round the reading was taken in.';

COMMENT ON COLUMN store.readings.read_at IS 'The collector''s clock when the reply arrived; see the batch''s clock_source.';

COMMENT ON COLUMN store.readings.value IS 'As sent, scale included: unrounded, in the unit of its profile version''s register.';

COMMENT ON COLUMN store.readings.product_code IS 'The product code the meter reported in that round; NULL only on rows stored before every reading had to carry one.';

ALTER TABLE store.readings
    ADD CONSTRAINT readings_key UNIQUE (meter_serial, register_key, read_at);

-- NOT VALID, as it was added: rows stored before readings carried a product
-- code keep none, since raw readings are never changed. Every row written
-- since must have one.
ALTER TABLE store.readings
    ADD CONSTRAINT readings_product_code_not_null NOT NULL product_code NOT VALID;

CREATE INDEX readings_batch_id_idx ON store.readings USING btree (batch_id);

CREATE INDEX readings_collector_id_read_at_idx ON store.readings USING btree (collector_id, read_at DESC);

CREATE INDEX readings_meter_serial_read_at_idx ON store.readings USING btree (meter_serial, read_at DESC);

CREATE INDEX readings_place_time ON store.readings USING btree (collector_id, endpoint_host, endpoint_port, unit_id, read_at);

ALTER TABLE store.readings
    ADD CONSTRAINT readings_batch_id_fkey FOREIGN KEY (batch_id) REFERENCES store.batches(batch_id);

ALTER TABLE store.readings
    ADD CONSTRAINT readings_collector_id_fkey FOREIGN KEY (collector_id) REFERENCES store.collectors(id);

ALTER TABLE store.readings
    ADD CONSTRAINT readings_profile_register FOREIGN KEY (profile, profile_version, register_key) REFERENCES store.profile_registers(profile, version, register_key);

-- A reading whose key is taken by a reading with other content.
-- contract: central/test/ingest.sql
CREATE TABLE store.reading_conflicts (
    meter_serial text CONSTRAINT readings_meter_serial_not_null NOT NULL,
    register_key text CONSTRAINT readings_register_key_not_null NOT NULL,
    read_at timestamp with time zone CONSTRAINT readings_read_at_not_null NOT NULL,
    value numeric CONSTRAINT readings_value_not_null NOT NULL,
    profile text CONSTRAINT readings_profile_not_null NOT NULL,
    endpoint_host text CONSTRAINT readings_endpoint_host_not_null NOT NULL,
    endpoint_port integer CONSTRAINT readings_endpoint_port_not_null NOT NULL,
    unit_id smallint CONSTRAINT readings_unit_id_not_null NOT NULL,
    collector_id text CONSTRAINT readings_collector_id_not_null NOT NULL,
    batch_id uuid CONSTRAINT readings_batch_id_not_null NOT NULL,
    received_at timestamp with time zone NOT NULL,
    product_code text,
    profile_version bigint NOT NULL
);

ALTER TABLE ONLY store.reading_conflicts
    ADD CONSTRAINT reading_conflicts_pkey PRIMARY KEY (batch_id, meter_serial, register_key, read_at);

-- NOT VALID, as on store.readings.
ALTER TABLE store.reading_conflicts
    ADD CONSTRAINT reading_conflicts_product_code_not_null NOT NULL product_code NOT VALID;

ALTER TABLE ONLY store.reading_conflicts
    ADD CONSTRAINT reading_conflicts_batch_id_fkey FOREIGN KEY (batch_id) REFERENCES store.batches(batch_id);

ALTER TABLE ONLY store.reading_conflicts
    ADD CONSTRAINT reading_conflicts_collector_id_fkey FOREIGN KEY (collector_id) REFERENCES store.collectors(id);

ALTER TABLE ONLY store.reading_conflicts
    ADD CONSTRAINT reading_conflicts_profile_register FOREIGN KEY (profile, profile_version, register_key) REFERENCES store.profile_registers(profile, version, register_key);

-- Reads that were due and did not happen, for the health views. Keyed on where
-- and when the read was due, since no serial may have been read: a host and
-- port are unique only per collector (registry.check_history).
-- contract: central/test/ingest.sql
CREATE TABLE store.missed_reads (
    meter_serial text,
    register_key text NOT NULL,
    read_at timestamp with time zone NOT NULL,
    reason store.missed_reason NOT NULL,
    exception_code smallint,
    detail text,
    attempts integer NOT NULL,
    raw_words integer[],
    profile text NOT NULL,
    endpoint_host text NOT NULL,
    endpoint_port integer NOT NULL,
    unit_id smallint NOT NULL,
    collector_id text NOT NULL,
    batch_id uuid NOT NULL,
    profile_version bigint NOT NULL,
    CONSTRAINT missed_reads_attempts_check CHECK ((attempts >= 0)),
    CONSTRAINT missed_reads_detail_check CHECK ((length(detail) <= 200)),
    CONSTRAINT missed_reads_exception_code_check CHECK (((exception_code >= 1) AND (exception_code <= 255)))
);

SELECT create_hypertable('store.missed_reads', by_range('read_at', INTERVAL '7 days'));

COMMENT ON COLUMN store.missed_reads.meter_serial IS 'The serial the meter reported in that round, or NULL when it could not be read.';

COMMENT ON COLUMN store.missed_reads.read_at IS 'When the read was due and given up on.';

COMMENT ON COLUMN store.missed_reads.raw_words IS 'The words read, where some were and no value came of them (reason decode); else NULL.';

ALTER TABLE store.missed_reads
    ADD CONSTRAINT missed_reads_key UNIQUE (collector_id, endpoint_host, endpoint_port, unit_id, register_key, read_at);

CREATE INDEX missed_reads_address_time ON store.missed_reads USING btree (collector_id, endpoint_host, endpoint_port, read_at);

CREATE INDEX missed_reads_meter_serial_read_at_idx ON store.missed_reads USING btree (meter_serial, read_at DESC);

CREATE INDEX missed_reads_place_time ON store.missed_reads USING btree (collector_id, endpoint_host, endpoint_port, unit_id, read_at);

ALTER TABLE store.missed_reads
    ADD CONSTRAINT missed_reads_batch_id_fkey FOREIGN KEY (batch_id) REFERENCES store.batches(batch_id);

ALTER TABLE store.missed_reads
    ADD CONSTRAINT missed_reads_collector_id_fkey FOREIGN KEY (collector_id) REFERENCES store.collectors(id);

ALTER TABLE store.missed_reads
    ADD CONSTRAINT missed_reads_profile_register FOREIGN KEY (profile, profile_version, register_key) REFERENCES store.profile_registers(profile, version, register_key);

-- The collector's clock measured against an NTP server (SNTP), as batch.v1's
-- clock_checks carry it: the four times raw, the server's header fields when
-- it answered, and the outcome when it did not. Offset, delay and error bound
-- are views (store.clock_offsets). Keyed on (collector, t1): a resent check is
-- a duplicate.
-- contract: central/test/ingest.sql
CREATE TABLE store.clock_checks (
  collector_id text NOT NULL REFERENCES store.collectors (id),
  t1 timestamptz NOT NULL,
  t4 timestamptz NOT NULL,
  trigger store.clock_check_trigger NOT NULL,
  server text NOT NULL CHECK (length(server) BETWEEN 1 AND 253),
  outcome store.clock_check_outcome NOT NULL,
  t2_unix numeric CHECK (scale(t2_unix) <= 9),
  t3_unix numeric CHECK (scale(t3_unix) <= 9),
  address inet,
  stratum smallint CHECK (stratum BETWEEN 1 AND 15),
  leap smallint CHECK (leap BETWEEN 0 AND 2),
  reference_id bigint CHECK (reference_id BETWEEN 0 AND 4294967295),
  batch_id uuid NOT NULL REFERENCES store.batches (batch_id),
  PRIMARY KEY (collector_id, t1),
  CONSTRAINT clock_checks_outcome_fields CHECK (CASE outcome
    WHEN 'answered' THEN num_nulls(t2_unix, t3_unix, address, stratum, leap, reference_id) = 0
    WHEN 'kiss_of_death' THEN num_nulls(address, reference_id) = 0
                              AND num_nonnulls(t2_unix, t3_unix, stratum, leap) = 0
    ELSE num_nonnulls(t2_unix, t3_unix, address, stratum, leap, reference_id) = 0
  END)
);

COMMENT ON COLUMN store.clock_checks.t1 IS 'The collector''s clock when it sent the query, or tried to.';

COMMENT ON COLUMN store.clock_checks.t4 IS 'The collector''s clock when the reply came, or it gave up waiting.';

COMMENT ON COLUMN store.clock_checks.t2_unix IS 'The server''s clock when it received the query: seconds since 1970-01-01T00:00:00Z (Unix time, no leap seconds), exact to the digits sent (at most nanoseconds). store.clock_offsets shows it as a timestamptz too.';

COMMENT ON COLUMN store.clock_checks.t3_unix IS 'The server''s clock when it sent its reply, as t2_unix.';

COMMENT ON COLUMN store.clock_checks.reference_id IS 'The reply''s reference identifier, its 32 bits unsigned; store.clock_check_references decodes it.';

CREATE INDEX clock_checks_collector_id_t1_idx ON store.clock_checks USING btree (collector_id, t1) WHERE (outcome = 'answered'::store.clock_check_outcome);

-- contract: central/test/latency.sql
CREATE TABLE store.latency_bucket_versions (
  version bigint PRIMARY KEY CHECK (version BETWEEN 1 AND 9007199254740991),
  bounds_ms integer[] NOT NULL CHECK (array_ndims(bounds_ms) = 1 AND cardinality(bounds_ms) >= 1),
  loaded_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE store.latency_bucket_versions IS 'Each version of contract/latency''s bucket bounds, loaded by bin/load-profiles. A version never changes; a change is a new version.';

COMMENT ON COLUMN store.latency_bucket_versions.bounds_ms IS 'Upper bounds in ms, increasing: bucket i (from 1) counts answers of at most bounds_ms[i] and more than bounds_ms[i - 1]; bucket cardinality + 1 counts answers above the last.';

-- Per meter, UTC day and poller run, how long its reads took to answer, in
-- the buckets of the version named, with retries, timeouts and late replies.
-- A poller that restarts in a day sends a second entry for it; views merge
-- them (store.latency_meter_days).
-- contract: central/test/ingest.sql, central/test/latency.sql
CREATE TABLE store.latency_days (
    collector_id text NOT NULL,
    endpoint_host text NOT NULL,
    endpoint_port integer NOT NULL,
    unit_id smallint NOT NULL,
    day date NOT NULL,
    poller_started_at timestamp with time zone NOT NULL,
    buckets_version bigint NOT NULL,
    retries bigint NOT NULL,
    timeouts bigint NOT NULL,
    max_ms bigint,
    buckets bigint[] NOT NULL,
    batch_id uuid NOT NULL,
    late_data bigint,
    late_exceptions jsonb,
    CONSTRAINT late_counted_whole CHECK (((late_data IS NULL) = (late_exceptions IS NULL))),
    CONSTRAINT latency_days_buckets_check CHECK (((array_ndims(buckets) = 1) AND (0 <= ALL (buckets)))),
    CONSTRAINT latency_days_late_data_check CHECK ((late_data >= 0)),
    CONSTRAINT latency_days_late_exceptions_check CHECK ((jsonb_typeof(late_exceptions) = 'object'::text)),
    CONSTRAINT latency_days_max_ms_check CHECK ((max_ms >= 0)),
    CONSTRAINT latency_days_retries_check CHECK ((retries >= 0)),
    CONSTRAINT latency_days_timeouts_check CHECK ((timeouts >= 0))
);

COMMENT ON COLUMN store.latency_days.day IS 'batch.v1''s date: the UTC date the requests were made on, by the collector''s clock.';

COMMENT ON COLUMN store.latency_days.poller_started_at IS 'When the poller that counted them started, by the collector''s clock: a restart''s part of a day is a row of its own.';

COMMENT ON COLUMN store.latency_days.buckets IS 'The answers in each bucket of buckets_version''s bounds, in order, every bucket given; the answers are their sum.';

COMMENT ON COLUMN store.latency_days.late_data IS 'Data replies from the unit that came too late for their request and were skipped as stale; NULL when the collector did not count late replies.';

COMMENT ON COLUMN store.latency_days.late_exceptions IS 'Late exception replies by exception code, in decimal: {"11": 2}; a code with none is absent. NULL exactly when late_data is.';

ALTER TABLE ONLY store.latency_days
    ADD CONSTRAINT latency_days_pkey PRIMARY KEY (collector_id, endpoint_host, endpoint_port, unit_id, day, poller_started_at);

CREATE INDEX latency_days_day ON store.latency_days USING btree (day);

ALTER TABLE ONLY store.latency_days
    ADD CONSTRAINT latency_days_batch_id_fkey FOREIGN KEY (batch_id) REFERENCES store.batches(batch_id);

ALTER TABLE ONLY store.latency_days
    ADD CONSTRAINT latency_days_buckets_version_fkey FOREIGN KEY (buckets_version) REFERENCES store.latency_bucket_versions(version);

ALTER TABLE ONLY store.latency_days
    ADD CONSTRAINT latency_days_collector_id_fkey FOREIGN KEY (collector_id) REFERENCES store.collectors(id);

-- The quantities a profile version copies from each store a meter keeps, with
-- each one's decode. Immutable with its version, as store.profile_registers.
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

COMMENT ON TABLE store.profile_stored IS 'Each profile version''s stored quantities, loaded from contract/profiles by bin/load-profiles; never changed.';

COMMENT ON COLUMN store.profile_stored.parameter IS 'Load survey only: the parameter number the selector is set to; its values are read at the section''s values register.';

-- Entries copied from a meter's own stores, stamped by the meter's clock
-- (local time, no zone). Keyed on (meter_serial, store, register_key,
-- meter_time): an entry copied again that says the same is a duplicate; where,
-- when and for what it was copied is evidence of the copy, not part of the
-- entry. One that says otherwise goes to store.stored_entry_conflicts.
-- contract: central/test/stored.sql
CREATE TABLE store.stored_entries (
  meter_serial text NOT NULL,
  store store.stored_store NOT NULL,
  register_key text NOT NULL,
  meter_time timestamp NOT NULL,
  value numeric NOT NULL,
  interval_s integer CHECK (interval_s BETWEEN 1 AND 86400),
  profile text NOT NULL,
  profile_version bigint NOT NULL,
  product_code text NOT NULL,
  slot integer NOT NULL CHECK (slot BETWEEN 0 AND 65535),
  copied_at timestamptz NOT NULL,
  request_id uuid,
  endpoint_host text NOT NULL,
  endpoint_port integer NOT NULL,
  unit_id smallint NOT NULL,
  collector_id text NOT NULL REFERENCES store.collectors (id),
  batch_id uuid NOT NULL REFERENCES store.batches (batch_id),
  CONSTRAINT stored_entries_key UNIQUE (meter_serial, store, register_key, meter_time),
  CONSTRAINT stored_entries_interval CHECK ((store = 'load_survey') = (interval_s IS NOT NULL)),
  CONSTRAINT stored_entries_profile_stored FOREIGN KEY (profile, profile_version, store, register_key)
    REFERENCES store.profile_stored (profile, version, store, register_key)
);

SELECT create_hypertable('store.stored_entries', by_range('meter_time', INTERVAL '7 days'));

COMMENT ON COLUMN store.stored_entries.meter_time IS 'The meter''s own stamp, decoded per the profile version: its local time, no zone. A load-survey entry''s is its interval''s start.';

COMMENT ON COLUMN store.stored_entries.value IS 'As sent: unrounded, in the unit of its profile version''s stored quantity.';

COMMENT ON COLUMN store.stored_entries.slot IS 'The selector value it was read at: evidence of the copy, never part of the key.';

COMMENT ON COLUMN store.stored_entries.copied_at IS 'The collector''s clock when the reply arrived; see the batch''s clock_source.';

COMMENT ON COLUMN store.stored_entries.request_id IS 'The request the entry was copied for, as first sent; no request kind asks for a copy, so nothing links it.';

CREATE INDEX stored_entries_batch_id_idx ON store.stored_entries USING btree (batch_id);

-- An entry whose key is taken by one that says something else.
-- contract: central/test/stored.sql
CREATE TABLE store.stored_entry_conflicts (
  LIKE store.stored_entries INCLUDING CONSTRAINTS,
  received_at timestamptz NOT NULL,
  PRIMARY KEY (batch_id, meter_serial, store, register_key, meter_time),
  FOREIGN KEY (collector_id) REFERENCES store.collectors (id),
  FOREIGN KEY (batch_id) REFERENCES store.batches (batch_id),
  FOREIGN KEY (profile, profile_version, store, register_key)
    REFERENCES store.profile_stored (profile, version, store, register_key)
);

-- A meter's clock as read beside the collector's, raw. Keyed as a firmware
-- read is, by where and when the collector read it: a resent read is a
-- duplicate, and one that says otherwise is kept as a conflict. Offsets are
-- views, grounded through the collector's clock checks.
-- contract: central/test/stored.sql
CREATE TABLE store.meter_clock_reads (
  collector_id text NOT NULL REFERENCES store.collectors (id),
  endpoint_host text NOT NULL,
  endpoint_port integer NOT NULL,
  unit_id smallint NOT NULL,
  collector_at timestamptz NOT NULL,
  meter_serial text NOT NULL,
  profile text NOT NULL,
  profile_version bigint NOT NULL,
  meter_time timestamp NOT NULL,
  batch_id uuid NOT NULL REFERENCES store.batches (batch_id),
  PRIMARY KEY (collector_id, endpoint_host, endpoint_port, unit_id, collector_at),
  FOREIGN KEY (profile, profile_version) REFERENCES store.profile_versions (profile, version)
);

COMMENT ON COLUMN store.meter_clock_reads.collector_at IS 'The collector''s clock when the meter''s clock was read; see the batch''s clock_source.';

COMMENT ON COLUMN store.meter_clock_reads.meter_time IS 'The meter''s clock as it read, decoded per the profile version: its local time, no zone.';

CREATE INDEX meter_clock_reads_batch_id_idx ON store.meter_clock_reads USING btree (batch_id);

CREATE INDEX meter_clock_reads_meter_serial_collector_at_idx ON store.meter_clock_reads USING btree (meter_serial, collector_at DESC);

-- A meter-clock read whose key is taken by one that says something else.
-- contract: central/test/stored.sql
CREATE TABLE store.meter_clock_read_conflicts (
  LIKE store.meter_clock_reads INCLUDING CONSTRAINTS,
  received_at timestamptz NOT NULL,
  PRIMARY KEY (batch_id, collector_id, endpoint_host, endpoint_port, unit_id, collector_at),
  FOREIGN KEY (collector_id) REFERENCES store.collectors (id),
  FOREIGN KEY (batch_id) REFERENCES store.batches (batch_id),
  FOREIGN KEY (profile, profile_version) REFERENCES store.profile_versions (profile, version)
);

-- A checked batch's clock checks as rows; none when it carries none.
CREATE FUNCTION store.batch_clock_checks(b jsonb) RETURNS TABLE(t1 timestamp with time zone, t4 timestamp with time zone, trigger store.clock_check_trigger, server text, outcome store.clock_check_outcome, t2_unix numeric, t3_unix numeric, address inet, stratum smallint, leap smallint, reference_id bigint)
    LANGUAGE sql STABLE
    AS $$
  SELECT (c ->> 't1')::timestamptz, (c ->> 't4')::timestamptz,
         (c ->> 'trigger')::store.clock_check_trigger, c ->> 'server',
         (c ->> 'outcome')::store.clock_check_outcome,
         store.unix_time(c ->> 't2'), store.unix_time(c ->> 't3'), (c ->> 'address')::inet,
         (c ->> 'stratum')::numeric::smallint, (c ->> 'leap')::numeric::smallint,
         (c ->> 'reference_id')::numeric::bigint
  FROM jsonb_array_elements(coalesce(b -> 'clock_checks', '[]')) c
$$;

-- A checked batch's fill results as rows; none when it carries none.
CREATE FUNCTION store.batch_fill_results(b jsonb) RETURNS TABLE(request_id uuid, meter_serial text, store store.stored_store, gone_before timestamp without time zone, finished_at timestamp with time zone, endpoint_host text, endpoint_port integer, unit_id smallint)
    LANGUAGE sql STABLE
    AS $$
  SELECT (r ->> 'request_id')::uuid, r ->> 'meter_serial', (r ->> 'store')::store.stored_store,
         (r ->> 'gone_before')::timestamp, (r ->> 'finished_at')::timestamptz,
         r -> 'endpoint' ->> 'host', (r -> 'endpoint' ->> 'port')::numeric::integer,
         (r ->> 'unit_id')::numeric::smallint
  FROM jsonb_array_elements(coalesce(b -> 'fill_results', '[]')) r
$$;

-- A checked batch's firmware reads as rows; none when it carries none.
CREATE FUNCTION store.batch_firmware_reads(b jsonb) RETURNS TABLE(meter_serial text, product_code text, read_at timestamp with time zone, software text, firmware_1 text, firmware_2 text, modbus_version text, endpoint_host text, endpoint_port integer, unit_id smallint)
    LANGUAGE sql STABLE
    AS $$
  SELECT f ->> 'meter_serial', f ->> 'product_code', (f ->> 'timestamp')::timestamptz,
         f ->> 'software', f ->> 'firmware_1', f ->> 'firmware_2', f ->> 'modbus_version',
         f -> 'endpoint' ->> 'host', (f -> 'endpoint' ->> 'port')::numeric::integer,
         (f ->> 'unit_id')::numeric::smallint
  FROM jsonb_array_elements(coalesce(b -> 'firmware_reads', '[]')) f
$$;

-- A checked batch's latency entries as rows; none when it carries none.
CREATE FUNCTION store.batch_latency_days(b jsonb) RETURNS TABLE(endpoint_host text, endpoint_port integer, unit_id smallint, day date, poller_started_at timestamp with time zone, buckets_version bigint, retries bigint, timeouts bigint, max_ms bigint, buckets bigint[], late_data bigint, late_exceptions jsonb)
    LANGUAGE sql STABLE
    AS $$
  SELECT l -> 'endpoint' ->> 'host', (l -> 'endpoint' ->> 'port')::numeric::integer,
         (l ->> 'unit_id')::numeric::smallint, (l ->> 'date')::date,
         (l ->> 'poller_started_at')::timestamptz, (l ->> 'buckets_version')::numeric::bigint,
         (l ->> 'retries')::numeric::bigint, (l ->> 'timeouts')::numeric::bigint,
         (l ->> 'max_ms')::numeric::bigint,
         ARRAY(SELECT (n #>> '{}')::numeric::bigint
               FROM jsonb_array_elements(l -> 'buckets') WITH ORDINALITY q(n, i) ORDER BY i),
         (l -> 'late' ->> 'data')::numeric::bigint,
         CASE WHEN l ? 'late' THEN coalesce(
           (SELECT jsonb_object_agg(x.key, (x.value #>> '{}')::numeric::bigint)
            FROM jsonb_each(l -> 'late' -> 'exceptions') x),
           '{}') END
  FROM jsonb_array_elements(coalesce(b -> 'latency', '[]')) l
$$;

-- A checked batch's meter-clock reads as rows; none when it carries none.
CREATE FUNCTION store.batch_meter_clock_reads(b jsonb) RETURNS TABLE(endpoint_host text, endpoint_port integer, unit_id smallint, collector_at timestamp with time zone, meter_serial text, profile text, profile_version bigint, meter_time timestamp without time zone)
    LANGUAGE sql STABLE
    AS $$
  SELECT m -> 'endpoint' ->> 'host', (m -> 'endpoint' ->> 'port')::numeric::integer,
         (m ->> 'unit_id')::numeric::smallint, (m ->> 'collector_at')::timestamptz,
         m ->> 'meter_serial', m ->> 'profile', (m ->> 'profile_version')::numeric::bigint,
         (m ->> 'meter_time')::timestamp
  FROM jsonb_array_elements(coalesce(b -> 'meter_clock_reads', '[]')) m
$$;

-- A checked batch's missed reads as rows.
CREATE FUNCTION store.batch_missed_reads(b jsonb) RETURNS TABLE(meter_serial text, register_key text, read_at timestamp with time zone, reason store.missed_reason, exception_code smallint, detail text, attempts integer, raw_words integer[], profile text, profile_version bigint, endpoint_host text, endpoint_port integer, unit_id smallint)
    LANGUAGE sql STABLE
    AS $$
  SELECT m ->> 'meter_serial', m ->> 'register_key', (m ->> 'timestamp')::timestamptz,
         (m ->> 'reason')::store.missed_reason, (m ->> 'exception_code')::numeric::smallint,
         m ->> 'detail', (m ->> 'attempts')::numeric::integer,
         CASE WHEN m -> 'raw_words' <> 'null'::jsonb THEN
           ARRAY(SELECT w::numeric::integer FROM jsonb_array_elements_text(m -> 'raw_words') w)
         END,
         m ->> 'profile', (m ->> 'profile_version')::numeric::bigint,
         m -> 'endpoint' ->> 'host', (m -> 'endpoint' ->> 'port')::numeric::integer,
         (m ->> 'unit_id')::numeric::smallint
  FROM jsonb_array_elements(b -> 'missed_reads') m
$$;

-- A checked batch's readings as rows, each value the decimal string it was sent as.
CREATE FUNCTION store.batch_readings(b jsonb) RETURNS TABLE(meter_serial text, register_key text, read_at timestamp with time zone, value numeric, profile text, profile_version bigint, endpoint_host text, endpoint_port integer, unit_id smallint, product_code text)
    LANGUAGE sql STABLE
    AS $$
  SELECT r ->> 'meter_serial', r ->> 'register_key', (r ->> 'timestamp')::timestamptz,
         (r ->> 'value')::numeric, r ->> 'profile', (r ->> 'profile_version')::numeric::bigint,
         r -> 'endpoint' ->> 'host', (r -> 'endpoint' ->> 'port')::numeric::integer,
         (r ->> 'unit_id')::numeric::smallint, r ->> 'product_code'
  FROM jsonb_array_elements(b -> 'readings') r
$$;

-- A checked batch's stored entries as rows; none when it carries none.
CREATE FUNCTION store.batch_stored_entries(b jsonb) RETURNS TABLE(meter_serial text, store store.stored_store, register_key text, meter_time timestamp without time zone, value numeric, interval_s integer, profile text, profile_version bigint, product_code text, slot integer, copied_at timestamp with time zone, request_id uuid, endpoint_host text, endpoint_port integer, unit_id smallint)
    LANGUAGE sql STABLE
    AS $$
  SELECT e ->> 'meter_serial', (e ->> 'store')::store.stored_store, e ->> 'register_key',
         (e ->> 'meter_time')::timestamp, (e ->> 'value')::numeric,
         (e ->> 'interval_s')::numeric::integer, e ->> 'profile',
         (e ->> 'profile_version')::numeric::bigint, e ->> 'product_code',
         (e ->> 'slot')::numeric::integer, (e ->> 'copied_at')::timestamptz,
         (e ->> 'request_id')::uuid, e -> 'endpoint' ->> 'host',
         (e -> 'endpoint' ->> 'port')::numeric::integer, (e ->> 'unit_id')::numeric::smallint
  FROM jsonb_array_elements(coalesce(b -> 'stored_entries', '[]')) e
$$;

-- The calling collector: PostgREST runs SET ROLE to the role its token names.
-- Inside SECURITY DEFINER, current_user is the owner but the role setting is
-- still the caller's.
CREATE FUNCTION store.caller() RETURNS text
    LANGUAGE sql STABLE
    AS $$
  SELECT id FROM store.collectors WHERE role = current_setting('role')::name
$$;

-- A JSON array of min_items to max_items items.
CREATE FUNCTION store.check_array(v jsonb, path text, min_items integer, max_items integer) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF jsonb_typeof(v) IS DISTINCT FROM 'array'
     OR jsonb_array_length(v) < min_items
     OR jsonb_array_length(v) > max_items THEN
    PERFORM store.reject(path, format('must be a list of %s to %s items', min_items, max_items));
  END IF;
END
$$;

-- A batch against contract/schema/batch.v1.schema.json, field by field,
-- rejecting (store.reject) at the first field that does not match. Optional
-- sections (the backlog's config, latency, stored entries, meter-clock reads,
-- fill results) are checked when present.
-- contract: central/test/schema.sql
CREATE FUNCTION store.check_batch(b jsonb) RETURNS void
    LANGUAGE plpgsql
    AS $_$
DECLARE
  e record;
BEGIN
  PERFORM store.check_object(b, 'batch', ARRAY[
    'schema_version', 'batch_id', 'sent_at', 'clock', 'backlog', 'readings', 'missed_reads'],
    ARRAY['firmware_reads', 'clock_checks', 'latency', 'stored_entries', 'meter_clock_reads',
          'fill_results']);
  IF b -> 'schema_version' <> '1'::jsonb THEN
    PERFORM store.reject('batch.schema_version', 'must be 1');
  END IF;
  PERFORM store.check_match(b -> 'batch_id', 'batch.batch_id',
    '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$', 'a UUID');
  PERFORM store.check_datetime(b -> 'sent_at', 'batch.sent_at');

  PERFORM store.check_object(b -> 'clock', 'batch.clock', ARRAY['source', 'last_sync_at']);
  PERFORM store.check_enum(b -> 'clock' -> 'source', 'batch.clock.source',
    enum_range(NULL::store.clock_source)::text[]);
  PERFORM store.check_nullable_datetime(b -> 'clock' -> 'last_sync_at', 'batch.clock.last_sync_at');

  PERFORM store.check_object(b -> 'backlog', 'batch.backlog', ARRAY[
    'events', 'bytes', 'batches', 'oldest', 'max_bytes', 'refused', 'discarded_files',
    'quarantined'], ARRAY['config']);
  IF b -> 'backlog' ? 'config' THEN
    PERFORM store.check_config_report(b -> 'backlog' -> 'config', 'batch.backlog.config');
  END IF;
  PERFORM store.check_count(b -> 'backlog' -> f, 'batch.backlog.' || f, 0)
    FROM unnest(ARRAY['events', 'bytes', 'batches', 'refused', 'discarded_files', 'quarantined']) f;
  PERFORM store.check_count(b -> 'backlog' -> 'max_bytes', 'batch.backlog.max_bytes', 1);
  PERFORM store.check_nullable_datetime(b -> 'backlog' -> 'oldest', 'batch.backlog.oldest');

  PERFORM store.check_array(b -> 'readings', 'batch.readings', 0, 2147483647);
  FOR e IN SELECT value, ordinality - 1 AS i FROM jsonb_array_elements(b -> 'readings') WITH ORDINALITY LOOP
    PERFORM store.check_reading(e.value, format('batch.readings[%s]', e.i));
  END LOOP;

  PERFORM store.check_array(b -> 'missed_reads', 'batch.missed_reads', 0, 2147483647);
  FOR e IN SELECT value, ordinality - 1 AS i FROM jsonb_array_elements(b -> 'missed_reads') WITH ORDINALITY LOOP
    PERFORM store.check_missed_read(e.value, format('batch.missed_reads[%s]', e.i));
  END LOOP;

  IF b ? 'firmware_reads' THEN
    PERFORM store.check_array(b -> 'firmware_reads', 'batch.firmware_reads', 0, 2147483647);
    FOR e IN SELECT value, ordinality - 1 AS i FROM jsonb_array_elements(b -> 'firmware_reads') WITH ORDINALITY LOOP
      PERFORM store.check_firmware_read(e.value, format('batch.firmware_reads[%s]', e.i));
    END LOOP;
  END IF;

  IF b ? 'clock_checks' THEN
    PERFORM store.check_array(b -> 'clock_checks', 'batch.clock_checks', 0, 2147483647);
    FOR e IN SELECT value, ordinality - 1 AS i FROM jsonb_array_elements(b -> 'clock_checks') WITH ORDINALITY LOOP
      PERFORM store.check_clock_check(e.value, format('batch.clock_checks[%s]', e.i));
    END LOOP;
  END IF;

  IF b ? 'latency' THEN
    PERFORM store.check_array(b -> 'latency', 'batch.latency', 0, 2147483647);
    FOR e IN SELECT value, ordinality - 1 AS i FROM jsonb_array_elements(b -> 'latency') WITH ORDINALITY LOOP
      PERFORM store.check_latency_day(e.value, format('batch.latency[%s]', e.i));
    END LOOP;
  END IF;

  IF b ? 'stored_entries' THEN
    PERFORM store.check_array(b -> 'stored_entries', 'batch.stored_entries', 0, 2147483647);
    FOR e IN SELECT value, ordinality - 1 AS i FROM jsonb_array_elements(b -> 'stored_entries') WITH ORDINALITY LOOP
      PERFORM store.check_stored_entry(e.value, format('batch.stored_entries[%s]', e.i));
    END LOOP;
  END IF;

  IF b ? 'meter_clock_reads' THEN
    PERFORM store.check_array(b -> 'meter_clock_reads', 'batch.meter_clock_reads', 0, 2147483647);
    FOR e IN SELECT value, ordinality - 1 AS i FROM jsonb_array_elements(b -> 'meter_clock_reads') WITH ORDINALITY LOOP
      PERFORM store.check_meter_clock_read(e.value, format('batch.meter_clock_reads[%s]', e.i));
    END LOOP;
  END IF;

  IF b ? 'fill_results' THEN
    PERFORM store.check_array(b -> 'fill_results', 'batch.fill_results', 0, 2147483647);
    FOR e IN SELECT value, ordinality - 1 AS i FROM jsonb_array_elements(b -> 'fill_results') WITH ORDINALITY LOOP
      PERFORM store.check_fill_result(e.value, format('batch.fill_results[%s]', e.i));
    END LOOP;
  END IF;
END
$_$;

-- A checked batch's readings and missed reads against the catalog. An event
-- under a profile version the store has not loaded is refused with 503, so
-- the collector keeps the batch and sends it again once the version is
-- loaded; one naming a register its version does not name, with 422.
-- contract: central/test/ingest.sql
CREATE FUNCTION store.check_catalog(b jsonb) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
  e record;
BEGIN
  FOR e IN
    SELECT kind, i, x ->> 'profile' AS profile, (x ->> 'profile_version')::numeric::bigint AS version,
           x ->> 'register_key' AS register_key
    FROM (SELECT 'readings' AS kind, ordinality - 1 AS i, value AS x
          FROM jsonb_array_elements(b -> 'readings') WITH ORDINALITY
          UNION ALL
          SELECT 'missed_reads', ordinality - 1, value
          FROM jsonb_array_elements(b -> 'missed_reads') WITH ORDINALITY) events
    WHERE NOT EXISTS (
      SELECT FROM store.profile_registers r
      WHERE (r.profile, r.version, r.register_key)
            = (x ->> 'profile', (x ->> 'profile_version')::numeric::bigint, x ->> 'register_key'))
    ORDER BY kind DESC, i
  LOOP
    IF NOT EXISTS (SELECT FROM store.profile_versions v
                   WHERE (v.profile, v.version) = (e.profile, e.version)) THEN
      RAISE SQLSTATE 'PT503' USING
        MESSAGE = format('batch.%s[%s]: profile %s version %s is not loaded in the store',
                         e.kind, e.i, e.profile, e.version),
        HINT = 'Load it with central/bin/load-profiles; the batch is accepted once it is.';
    END IF;
    PERFORM store.reject(format('batch.%s[%s].register_key', e.kind, e.i),
      format('is not a register of profile %s version %s', e.profile, e.version));
  END LOOP;
END
$$;

-- The fields an outcome carries: answered, the server's times and header
-- fields; kiss_of_death, the address and kiss code; any other, none.
-- contract: central/test/schema.sql
CREATE FUNCTION store.check_clock_check(v jsonb, path text) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
  always text[] := ARRAY['trigger', 'server', 'outcome', 't1', 't4'];
  answer text[] := ARRAY['t2', 't3', 'address', 'stratum', 'leap', 'reference_id'];
BEGIN
  PERFORM store.check_object(v, path, always, answer);
  PERFORM store.check_enum(v -> 'outcome', path || '.outcome',
    enum_range(NULL::store.clock_check_outcome)::text[]);
  PERFORM store.check_object(v, path, always || CASE v ->> 'outcome'
    WHEN 'answered' THEN answer
    WHEN 'kiss_of_death' THEN ARRAY['address', 'reference_id']
    ELSE '{}'::text[]
  END);
  PERFORM store.check_enum(v -> 'trigger', path || '.trigger',
    enum_range(NULL::store.clock_check_trigger)::text[]);
  PERFORM store.check_string(v -> 'server', path || '.server', 253);
  PERFORM store.check_time(v -> t, path || '.' || t, 6, 'microseconds')
    FROM unnest(ARRAY['t1', 't4']) t;
  IF v ? 't2' THEN
    PERFORM store.check_time(v -> t, path || '.' || t, 9, 'nanoseconds')
      FROM unnest(ARRAY['t2', 't3']) t;
    PERFORM store.check_integer(v -> 'stratum', path || '.stratum', 1, 15);
    PERFORM store.check_integer(v -> 'leap', path || '.leap', 0, 2);
  END IF;
  IF v ? 'address' THEN
    PERFORM store.check_ip(v -> 'address', path || '.address');
    PERFORM store.check_integer(v -> 'reference_id', path || '.reference_id', 0, 4294967295);
  END IF;
END
$$;

-- contract: central/test/schema.sql
CREATE FUNCTION store.check_config_report(v jsonb, path text) RETURNS void
    LANGUAGE plpgsql
    AS $_$
BEGIN
  PERFORM store.check_object(v, path, ARRAY['digest', 'refused_digest', 'reason']);
  PERFORM store.check_match(v -> 'digest', path || '.digest', '^[0-9a-f]{64}$',
                            'a SHA-256 digest in lowercase hex');
  IF v -> 'refused_digest' = 'null'::jsonb THEN
    IF v -> 'reason' <> 'null'::jsonb THEN
      PERFORM store.reject(path || '.reason', 'must be null when refused_digest is');
    END IF;
    RETURN;
  END IF;
  PERFORM store.check_match(v -> 'refused_digest', path || '.refused_digest', '^[0-9a-f]{64}$',
                            'null or a SHA-256 digest in lowercase hex');
  PERFORM store.check_string(v -> 'reason', path || '.reason', 1000);
END
$_$;

-- A checked batch's stored entries and meter-clock reads against the catalog.
-- One under a profile version the store has not loaded is refused with 503,
-- as a reading is; an entry whose quantity its version does not hold in its
-- store, with 422.
-- contract: central/test/stored.sql
CREATE FUNCTION store.check_copied_catalog(b jsonb) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
  e record;
BEGIN
  FOR e IN
    SELECT kind, i, x ->> 'profile' AS profile, (x ->> 'profile_version')::numeric::bigint AS version,
           x ->> 'store' AS store, x ->> 'register_key' AS register_key
    FROM (SELECT 'stored_entries' AS kind, ordinality - 1 AS i, value AS x
          FROM jsonb_array_elements(coalesce(b -> 'stored_entries', '[]')) WITH ORDINALITY
          UNION ALL
          SELECT 'meter_clock_reads', ordinality - 1, value
          FROM jsonb_array_elements(coalesce(b -> 'meter_clock_reads', '[]')) WITH ORDINALITY) events
    WHERE NOT EXISTS (
      SELECT FROM store.profile_stored s
      WHERE (s.profile, s.version, s.store::text, s.register_key)
            = (x ->> 'profile', (x ->> 'profile_version')::numeric::bigint, x ->> 'store',
               x ->> 'register_key'))
    ORDER BY kind DESC, i
  LOOP
    IF NOT EXISTS (SELECT FROM store.profile_versions v
                   WHERE (v.profile, v.version) = (e.profile, e.version)) THEN
      RAISE SQLSTATE 'PT503' USING
        MESSAGE = format('batch.%s[%s]: profile %s version %s is not loaded in the store',
                         e.kind, e.i, e.profile, e.version),
        HINT = 'Load it with central/bin/load-profiles; the batch is accepted once it is.';
    END IF;
    IF e.kind = 'stored_entries' THEN
      PERFORM store.reject(format('batch.%s[%s].register_key', e.kind, e.i),
        format('is not a %s quantity of profile %s version %s', e.store, e.profile, e.version));
    END IF;
  END LOOP;
END
$$;

-- The endpoint, unit, serial and profile version a stored entry and a
-- meter-clock read share.
CREATE FUNCTION store.check_copied_meter(v jsonb, path text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM store.check_object(v -> 'endpoint', path || '.endpoint', ARRAY['host', 'port']);
  PERFORM store.check_string(v -> 'endpoint' -> 'host', path || '.endpoint.host', 2147483647);
  PERFORM store.check_integer(v -> 'endpoint' -> 'port', path || '.endpoint.port', 1, 65535);
  PERFORM store.check_integer(v -> 'unit_id', path || '.unit_id', 1, 247);
  PERFORM store.check_string(v -> 'meter_serial', path || '.meter_serial', 2147483647);
  PERFORM store.check_string(v -> 'profile', path || '.profile', 2147483647);
  PERFORM store.check_count(v -> 'profile_version', path || '.profile_version', 1);
  PERFORM store.check_meter_time(v -> 'meter_time', path || '.meter_time');
END
$$;

-- The schema caps counts at 2^53 - 1, which bigint holds.
CREATE FUNCTION store.check_count(v jsonb, path text, lo numeric) RETURNS void
    LANGUAGE sql
    AS $$
  SELECT store.check_integer(v, path, lo, 9007199254740991)
$$;

-- JSON Schema's "date", as batch.v1 writes it: YYYY-MM-DD, a day that exists.
CREATE FUNCTION store.check_date(v jsonb, path text) RETURNS void
    LANGUAGE plpgsql
    AS $_$
BEGIN
  PERFORM store.check_match(v, path, '^[0-9]{4}-[0-9]{2}-[0-9]{2}$', 'a date such as 2026-11-01');
  PERFORM (v #>> '{}')::date;
EXCEPTION
  WHEN datetime_field_overflow OR invalid_datetime_format THEN
    PERFORM store.reject(path, 'is not a date that exists');
END
$_$;

-- JSON Schema's "date-time" (RFC 3339): an offset is required, T and Z may be
-- lower case, no leap second.
CREATE FUNCTION store.check_datetime(v jsonb, path text) RETURNS void
    LANGUAGE plpgsql
    AS $_$
BEGIN
  PERFORM store.check_match(v, path,
    '^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])[Tt]([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]'
    || '(\.[0-9]+)?([Zz]|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$',
    'an RFC 3339 date-time with an offset');
  PERFORM (v #>> '{}')::timestamptz;
EXCEPTION
  WHEN datetime_field_overflow OR invalid_datetime_format THEN
    PERFORM store.reject(path, 'is not a date that exists');
END
$_$;

-- A JSON string among allowed.
CREATE FUNCTION store.check_enum(v jsonb, path text, allowed text[]) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF jsonb_typeof(v) IS DISTINCT FROM 'string' OR (v #>> '{}') <> ALL (allowed) THEN
    PERFORM store.reject(path, 'must be one of ' || array_to_string(allowed, ', '));
  END IF;
END
$$;

-- The fields a reading and a missed read share; the serial is checked by each.
-- contract: central/test/schema.sql
CREATE FUNCTION store.check_event(v jsonb, path text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM store.check_object(v -> 'endpoint', path || '.endpoint', ARRAY['host', 'port']);
  PERFORM store.check_string(v -> 'endpoint' -> 'host', path || '.endpoint.host', 2147483647);
  PERFORM store.check_integer(v -> 'endpoint' -> 'port', path || '.endpoint.port', 1, 65535);
  PERFORM store.check_integer(v -> 'unit_id', path || '.unit_id', 1, 247);
  PERFORM store.check_string(v -> 'profile', path || '.profile', 2147483647);
  PERFORM store.check_count(v -> 'profile_version', path || '.profile_version', 1);
  PERFORM store.check_string(v -> 'register_key', path || '.register_key', 2147483647);
  PERFORM store.check_datetime(v -> 'timestamp', path || '.timestamp');
END
$$;

-- contract: central/test/schema.sql
CREATE FUNCTION store.check_fill_result(v jsonb, path text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM store.check_object(v, path, ARRAY[
    'request_id', 'endpoint', 'unit_id', 'meter_serial', 'store', 'gone_before', 'finished_at']);
  PERFORM store.check_uuid(v -> 'request_id', path || '.request_id');
  PERFORM store.check_object(v -> 'endpoint', path || '.endpoint', ARRAY['host', 'port']);
  PERFORM store.check_string(v -> 'endpoint' -> 'host', path || '.endpoint.host', 2147483647);
  PERFORM store.check_integer(v -> 'endpoint' -> 'port', path || '.endpoint.port', 1, 65535);
  PERFORM store.check_integer(v -> 'unit_id', path || '.unit_id', 1, 247);
  PERFORM store.check_string(v -> 'meter_serial', path || '.meter_serial', 2147483647);
  PERFORM store.check_enum(v -> 'store', path || '.store',
    enum_range(NULL::store.stored_store)::text[]);
  IF v -> 'gone_before' <> 'null'::jsonb THEN
    PERFORM store.check_meter_time(v -> 'gone_before', path || '.gone_before');
  END IF;
  PERFORM store.check_time(v -> 'finished_at', path || '.finished_at', 6, 'microseconds');
END
$$;

-- A firmware read's fields; a name the meter did not give is null.
-- contract: central/test/schema.sql
CREATE FUNCTION store.check_firmware_read(v jsonb, path text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM store.check_object(v, path, ARRAY[
    'endpoint', 'unit_id', 'meter_serial', 'product_code', 'timestamp', 'software',
    'firmware_1', 'firmware_2', 'modbus_version']);
  PERFORM store.check_object(v -> 'endpoint', path || '.endpoint', ARRAY['host', 'port']);
  PERFORM store.check_string(v -> 'endpoint' -> 'host', path || '.endpoint.host', 2147483647);
  PERFORM store.check_integer(v -> 'endpoint' -> 'port', path || '.endpoint.port', 1, 65535);
  PERFORM store.check_integer(v -> 'unit_id', path || '.unit_id', 1, 247);
  PERFORM store.check_string(v -> 'meter_serial', path || '.meter_serial', 2147483647);
  PERFORM store.check_string(v -> 'product_code', path || '.product_code', 2147483647);
  PERFORM store.check_datetime(v -> 'timestamp', path || '.timestamp');
  PERFORM store.check_name(v -> n, path || '.' || n)
    FROM unnest(ARRAY['software', 'firmware_1', 'firmware_2', 'modbus_version']) n;
END
$$;

-- A JSON integer: 502.0 counts.
CREATE FUNCTION store.check_integer(v jsonb, path text, lo numeric, hi numeric) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF jsonb_typeof(v) IS DISTINCT FROM 'number'
     OR v::numeric <> trunc(v::numeric)
     OR v::numeric < lo
     OR v::numeric > hi THEN
    PERFORM store.reject(path, format('must be an integer from %s to %s', lo, hi));
  END IF;
END
$$;

-- JSON Schema's "ipv4" (dotted decimal, no leading zeros) or "ipv6" (no
-- prefix length, no zone).
CREATE FUNCTION store.check_ip(v jsonb, path text) RETURNS void
    LANGUAGE plpgsql
    AS $_$
DECLARE
  octet text := '(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])';
  s text := v #>> '{}';
BEGIN
  IF jsonb_typeof(v) = 'string'
     AND (s ~ format('^%s(\.%s){3}$', octet, octet)
          OR (s ~ '^[0-9A-Fa-f:.]*:[0-9A-Fa-f:.]*$' AND family(s::inet) = 6)) THEN
    RETURN;
  END IF;
  PERFORM store.reject(path, 'must be an IPv4 or IPv6 address');
EXCEPTION
  WHEN invalid_text_representation THEN
    PERFORM store.reject(path, 'must be an IPv4 or IPv6 address');
END
$_$;

-- contract: central/test/schema.sql
CREATE FUNCTION store.check_late(v jsonb, path text) RETURNS void
    LANGUAGE plpgsql
    AS $_$
DECLARE
  e record;
BEGIN
  PERFORM store.check_object(v, path, ARRAY['data', 'exceptions']);
  PERFORM store.check_count(v -> 'data', path || '.data', 0);
  IF jsonb_typeof(v -> 'exceptions') <> 'object' THEN
    PERFORM store.reject(path || '.exceptions', 'must be an object of counts by exception code');
  END IF;
  FOR e IN SELECT key, value FROM jsonb_each(v -> 'exceptions') LOOP
    IF e.key !~ '^([1-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])$' THEN
      PERFORM store.reject(path || '.exceptions',
        format('%s is not an exception code: 1 to 255, in decimal', quote_literal(left(e.key, 20))));
    END IF;
    PERFORM store.check_count(e.value, format('%s.exceptions.%s', path, e.key), 1);
  END LOOP;
END
$_$;

-- A checked batch's latency entries against the bucket versions and
-- themselves. An entry under a version the store has not loaded is refused
-- with 503, so the collector keeps the batch until it is; with 422, one whose
-- buckets are not one per bound and one above the last, whose retries
-- outnumber its answers (the sum of its buckets), whose max_ms is given with
-- no answer, missing with some, or not in its last bucket that counts any,
-- or whose poller started after its date ended.
-- contract: central/test/ingest.sql
CREATE FUNCTION store.check_latency(b jsonb) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
  e record;
  path text;
  bounds integer[];
  answered numeric;
  k integer;
BEGIN
  FOR e IN
    SELECT ordinality - 1 AS i, l.*
    FROM store.batch_latency_days(b) WITH ORDINALITY l
  LOOP
    path := format('batch.latency[%s]', e.i);
    SELECT v.bounds_ms INTO bounds FROM store.latency_bucket_versions v
      WHERE v.version = e.buckets_version;
    IF NOT FOUND THEN
      RAISE SQLSTATE 'PT503' USING
        MESSAGE = format('%s: latency buckets version %s is not loaded in the store',
                         path, e.buckets_version),
        HINT = 'Load it with central/bin/load-profiles; the batch is accepted once it is.';
    END IF;
    IF cardinality(e.buckets) <> cardinality(bounds) + 1 THEN
      PERFORM store.reject(path || '.buckets', format(
        'must have %s counts, one per bound of latency buckets version %s and one above the last',
        cardinality(bounds) + 1, e.buckets_version));
    END IF;
    SELECT sum(n), max(i) FILTER (WHERE n > 0) INTO answered, k
      FROM unnest(e.buckets) WITH ORDINALITY u(n, i);
    IF e.retries > answered THEN
      PERFORM store.reject(path || '.retries', 'must be at most the answers, the sum of buckets');
    END IF;
    IF answered = 0 AND e.max_ms IS NOT NULL THEN
      PERFORM store.reject(path || '.max_ms', 'must be null when nothing answered');
    END IF;
    IF answered > 0 AND e.max_ms IS NULL THEN
      PERFORM store.reject(path || '.max_ms', 'must be given when something answered');
    END IF;
    IF answered > 0 AND NOT ((k = 1 OR e.max_ms > bounds[k - 1])
                             AND (k > cardinality(bounds) OR e.max_ms <= bounds[k])) THEN
      PERFORM store.reject(path || '.max_ms', format(
        'must be in the last bucket that counts an answer: %s',
        concat_ws(' and ', 'above ' || bounds[k - 1] || ' ms', 'at most ' || bounds[k] || ' ms')));
    END IF;
    IF e.poller_started_at >= (e.day + 1)::timestamp AT TIME ZONE 'UTC' THEN
      PERFORM store.reject(path || '.poller_started_at', 'must be before its date ended (UTC)');
    END IF;
  END LOOP;
END
$$;

-- A latency entry's fields, with its optional late counts: late data and late
-- exceptions by code.
-- contract: central/test/schema.sql
CREATE FUNCTION store.check_latency_day(v jsonb, path text) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
  e record;
BEGIN
  PERFORM store.check_object(v, path, ARRAY[
    'endpoint', 'unit_id', 'date', 'poller_started_at', 'buckets_version', 'retries',
    'timeouts', 'max_ms', 'buckets'], ARRAY['late']);
  PERFORM store.check_object(v -> 'endpoint', path || '.endpoint', ARRAY['host', 'port']);
  PERFORM store.check_string(v -> 'endpoint' -> 'host', path || '.endpoint.host', 2147483647);
  PERFORM store.check_integer(v -> 'endpoint' -> 'port', path || '.endpoint.port', 1, 65535);
  PERFORM store.check_integer(v -> 'unit_id', path || '.unit_id', 1, 247);
  PERFORM store.check_date(v -> 'date', path || '.date');
  PERFORM store.check_time(v -> 'poller_started_at', path || '.poller_started_at', 6,
                           'microseconds');
  PERFORM store.check_count(v -> 'buckets_version', path || '.buckets_version', 1);
  PERFORM store.check_count(v -> f, path || '.' || f, 0)
    FROM unnest(ARRAY['retries', 'timeouts']) f;
  IF v -> 'max_ms' <> 'null'::jsonb THEN
    PERFORM store.check_count(v -> 'max_ms', path || '.max_ms', 0);
  END IF;
  PERFORM store.check_array(v -> 'buckets', path || '.buckets', 2, 2147483647);
  FOR e IN SELECT value, ordinality - 1 AS i FROM jsonb_array_elements(v -> 'buckets') WITH ORDINALITY LOOP
    PERFORM store.check_count(e.value, format('%s.buckets[%s]', path, e.i), 0);
  END LOOP;
  IF v ? 'late' THEN
    PERFORM store.check_late(v -> 'late', path || '.late');
  END IF;
END
$$;

-- A JSON string matching pattern; what names it in the rejection.
CREATE FUNCTION store.check_match(v jsonb, path text, pattern text, what text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF jsonb_typeof(v) IS DISTINCT FROM 'string' OR (v #>> '{}') !~ pattern THEN
    PERFORM store.reject(path, 'must be ' || what);
  END IF;
END
$$;

-- contract: central/test/schema.sql
CREATE FUNCTION store.check_meter_clock_read(v jsonb, path text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM store.check_object(v, path, ARRAY[
    'endpoint', 'unit_id', 'meter_serial', 'profile', 'profile_version', 'meter_time',
    'collector_at']);
  PERFORM store.check_copied_meter(v, path);
  PERFORM store.check_time(v -> 'collector_at', path || '.collector_at', 6, 'microseconds');
END
$$;

-- batch.v1's meter_time: a local date-time to the second, no zone or offset,
-- on a day that exists. The schema's pattern cannot see the day; no decoded
-- stamp lands on one that does not exist.
CREATE FUNCTION store.check_meter_time(v jsonb, path text) RETURNS void
    LANGUAGE plpgsql
    AS $_$
BEGIN
  PERFORM store.check_match(v, path,
    '^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]$',
    'a local date-time with no zone, such as 2026-11-01T00:00:00');
  PERFORM (v #>> '{}')::timestamp;
EXCEPTION
  WHEN datetime_field_overflow OR invalid_datetime_format THEN
    PERFORM store.reject(path, 'is not a date that exists');
END
$_$;

-- contract: central/test/schema.sql
CREATE FUNCTION store.check_missed_read(v jsonb, path text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM store.check_object(v, path, ARRAY[
    'endpoint', 'unit_id', 'meter_serial', 'profile', 'profile_version', 'register_key',
    'timestamp', 'reason', 'exception_code', 'detail', 'attempts', 'raw_words'],
    ARRAY['request_id']);
  PERFORM store.check_event(v, path);
  IF v -> 'meter_serial' <> 'null'::jsonb THEN
    PERFORM store.check_string(v -> 'meter_serial', path || '.meter_serial', 2147483647);
  END IF;
  PERFORM store.check_enum(v -> 'reason', path || '.reason',
    enum_range(NULL::store.missed_reason)::text[]);
  IF v -> 'exception_code' <> 'null'::jsonb THEN
    PERFORM store.check_integer(v -> 'exception_code', path || '.exception_code', 1, 255);
  END IF;
  IF v -> 'detail' <> 'null'::jsonb THEN
    PERFORM store.check_string(v -> 'detail', path || '.detail', 200);
  END IF;
  PERFORM store.check_count(v -> 'attempts', path || '.attempts', 0);
  IF v -> 'raw_words' <> 'null'::jsonb THEN
    PERFORM store.check_words(v -> 'raw_words', path || '.raw_words', 0, 125);
  END IF;
  IF v ? 'request_id' THEN
    PERFORM store.check_uuid(v -> 'request_id', path || '.request_id');
  END IF;
END
$$;

-- A name as decoded: printable ASCII with nothing to trim, at most the 125
-- registers a read returns, two characters each.
CREATE FUNCTION store.check_name(v jsonb, path text) RETURNS void
    LANGUAGE plpgsql
    AS $_$
BEGIN
  IF v <> 'null'::jsonb THEN
    PERFORM store.check_string(v, path, 250);
    PERFORM store.check_match(v, path, '^[!-~]([ -~]*[!-~])?$',
      'printable ASCII with no leading or trailing space');
  END IF;
END
$_$;

-- A date-time as store.check_datetime, or null.
CREATE FUNCTION store.check_nullable_datetime(v jsonb, path text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF v <> 'null'::jsonb THEN
    PERFORM store.check_datetime(v, path);
  END IF;
END
$$;

-- A JSON object with exactly these fields.
CREATE FUNCTION store.check_object(v jsonb, path text, fields text[]) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM store.check_object(v, path, fields, '{}'::text[]);
END
$$;

-- A JSON object with every one of fields, and of optional any or none.
CREATE FUNCTION store.check_object(v jsonb, path text, fields text[], optional text[]) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
  missing text;
  unknown text;
BEGIN
  IF jsonb_typeof(v) IS DISTINCT FROM 'object' THEN
    PERFORM store.reject(path, 'must be an object');
  END IF;
  SELECT string_agg(f, ', ' ORDER BY f) INTO missing FROM unnest(fields) f WHERE NOT v ? f;
  IF missing IS NOT NULL THEN
    PERFORM store.reject(path, 'is missing ' || missing);
  END IF;
  SELECT string_agg(k, ', ' ORDER BY k) INTO unknown
    FROM jsonb_object_keys(v) k WHERE k <> ALL (fields || optional);
  IF unknown IS NOT NULL THEN
    PERFORM store.reject(path, 'has unknown field(s) ' || unknown);
  END IF;
END
$$;

-- contract: central/test/schema.sql
CREATE FUNCTION store.check_reading(v jsonb, path text) RETURNS void
    LANGUAGE plpgsql
    AS $_$
BEGIN
  PERFORM store.check_object(v, path, ARRAY[
    'endpoint', 'unit_id', 'meter_serial', 'product_code', 'profile', 'profile_version',
    'register_key', 'timestamp', 'value'], ARRAY['request_id']);
  PERFORM store.check_event(v, path);
  PERFORM store.check_string(v -> 'meter_serial', path || '.meter_serial', 2147483647);
  PERFORM store.check_string(v -> 'product_code', path || '.product_code', 2147483647);
  PERFORM store.check_match(v -> 'value', path || '.value', '^-?[0-9]+(\.[0-9]+)?$',
    'a decimal string such as "1234.56"');
  IF v ? 'request_id' THEN
    PERFORM store.check_uuid(v -> 'request_id', path || '.request_id');
  END IF;
END
$_$;

-- A load-survey entry carries its interval; no other entry has one.
-- contract: central/test/schema.sql
CREATE FUNCTION store.check_stored_entry(v jsonb, path text) RETURNS void
    LANGUAGE plpgsql
    AS $_$
DECLARE
  fields text[] := ARRAY[
    'endpoint', 'unit_id', 'meter_serial', 'product_code', 'profile', 'profile_version', 'store',
    'meter_time', 'register_key', 'value', 'slot', 'copied_at'];
BEGIN
  PERFORM store.check_object(v, path, fields, ARRAY['interval_s', 'request_id']);
  PERFORM store.check_enum(v -> 'store', path || '.store',
    enum_range(NULL::store.stored_store)::text[]);
  IF v ->> 'store' = 'load_survey' THEN
    PERFORM store.check_object(v, path, fields || ARRAY['interval_s'], ARRAY['request_id']);
    PERFORM store.check_integer(v -> 'interval_s', path || '.interval_s', 1, 86400);
  ELSE
    PERFORM store.check_object(v, path, fields, ARRAY['request_id']);
  END IF;
  PERFORM store.check_copied_meter(v, path);
  PERFORM store.check_string(v -> 'product_code', path || '.product_code', 2147483647);
  PERFORM store.check_string(v -> 'register_key', path || '.register_key', 2147483647);
  PERFORM store.check_match(v -> 'value', path || '.value', '^-?[0-9]+(\.[0-9]+)?$',
    'a decimal string such as "1234.56"');
  PERFORM store.check_integer(v -> 'slot', path || '.slot', 0, 65535);
  PERFORM store.check_time(v -> 'copied_at', path || '.copied_at', 6, 'microseconds');
  IF v ? 'request_id' THEN
    PERFORM store.check_uuid(v -> 'request_id', path || '.request_id');
  END IF;
END
$_$;

-- A JSON string of 1 to max_length characters.
CREATE FUNCTION store.check_string(v jsonb, path text, max_length integer) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF jsonb_typeof(v) IS DISTINCT FROM 'string'
     OR length(v #>> '{}') < 1
     OR length(v #>> '{}') > max_length THEN
    PERFORM store.reject(path, format('must be a string of 1 to %s characters', max_length));
  END IF;
END
$$;

-- A date-time to at most `digits` fraction digits.
CREATE FUNCTION store.check_time(v jsonb, path text, digits integer, finest text) RETURNS void
    LANGUAGE plpgsql
    AS $_$
BEGIN
  PERFORM store.check_datetime(v, path);
  PERFORM store.check_match(v, path,
    format('^[^.]*(\.[0-9]{1,%s})?([Zz]|[+-][0-9]{2}:[0-9]{2})$', digits),
    'a date-time to at most ' || finest);
END
$_$;

-- A UUID as JSON Schema's "uuid" format accepts it.
CREATE FUNCTION store.check_uuid(v jsonb, path text) RETURNS void
    LANGUAGE sql
    AS $_$
  SELECT store.check_match(v, path,
    '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$', 'a UUID')
$_$;

-- Raw register words: a list of min_items to max_items integers, each 0 to 65535.
CREATE FUNCTION store.check_words(v jsonb, path text, min_items integer, max_items integer) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
  w record;
BEGIN
  PERFORM store.check_array(v, path, min_items, max_items);
  FOR w IN SELECT value, ordinality - 1 AS i FROM jsonb_array_elements(v) WITH ORDINALITY LOOP
    PERFORM store.check_integer(w.value, format('%s[%s]', path, w.i), 0, 65535);
  END LOOP;
END
$$;


-- A profile file's registers as catalog rows, at its version.
CREATE FUNCTION store.profile_document_registers(document jsonb, version bigint) RETURNS SETOF store.profile_registers
    LANGUAGE sql IMMUTABLE
    AS $$
  SELECT document ->> 'profile', version, r ->> 'key', (r ->> 'table')::store.register_table,
         (r ->> 'address')::integer, (r ->> 'type')::store.register_type,
         (r ->> 'word_order')::store.word_order, (r ->> 'decimals')::smallint,
         (r ->> 'unit')::store.reading_unit, (r ->> 'kind')::store.register_kind
  FROM jsonb_array_elements(document -> 'registers') r
$$;

-- A profile file's stored quantities as catalog rows, at its version; none
-- for a file with no stored section.
CREATE FUNCTION store.profile_document_stored(document jsonb, version bigint) RETURNS SETOF store.profile_stored
    LANGUAGE sql IMMUTABLE
    AS $$
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

-- Raw data is never changed or deleted: every store table has this trigger
-- for UPDATE and DELETE, and refuse_truncate for TRUNCATE.
-- contract: central/test/ingest.sql
CREATE FUNCTION store.refuse_change() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION '% on %.% refused: raw data is never changed or deleted',
    TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME
    USING HINT = 'Corrections are separate records that reference the raw data.';
END
$$;

-- Refuse the batch with 422 (PostgREST's PT422), naming the field and what is
-- wrong with it.
CREATE FUNCTION store.reject(path text, problem text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE SQLSTATE 'PT422' USING
    MESSAGE = format('batch rejected: %s %s', path, problem),
    HINT = 'A batch must match contract/schema/batch.v1.schema.json.';
END
$$;

-- A checked date-time as Unix time, every fraction digit kept: the whole
-- seconds through timestamptz, the fraction as written.
CREATE FUNCTION store.unix_time(t text) RETURNS numeric
    LANGUAGE sql STABLE STRICT
    AS $$
  SELECT extract(epoch FROM regexp_replace(t, '\.[0-9]+', '')::timestamptz)::bigint
         + coalesce(('0' || substring(t FROM '\.[0-9]+'))::numeric, 0)
$$;

-- Each table listed refuses UPDATE, DELETE and TRUNCATE (store.refuse_change).
DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'batches',
    'uploads',
    'firmware_reads',
    'profile_versions',
    'profile_registers',
    'readings',
    'reading_conflicts',
    'missed_reads',
    'clock_checks',
    'latency_bucket_versions',
    'latency_days',
    'profile_stored',
    'stored_entries',
    'stored_entry_conflicts',
    'meter_clock_reads',
    'meter_clock_read_conflicts'
  ] LOOP
    EXECUTE format(
      'CREATE TRIGGER refuse_change BEFORE UPDATE OR DELETE ON store.%I
         FOR EACH ROW EXECUTE FUNCTION store.refuse_change()', t);
    EXECUTE format(
      'CREATE TRIGGER refuse_truncate BEFORE TRUNCATE ON store.%I
         FOR EACH STATEMENT EXECUTE FUNCTION store.refuse_change()', t);
  END LOOP;
END
$$;

-- Each reference identifier decoded (RFC 5905): a kiss code (kiss_of_death)
-- or a stratum 1 server's source as up to four ASCII characters, NULs
-- dropped and anything else unprintable as ?; any other stratum's as a dotted
-- quad (a server's IPv4 address; for an IPv6 server, a hash of its address).
-- contract: central/test/clock.sql
CREATE VIEW store.clock_check_references AS
  SELECT c.collector_id, c.t1, c.outcome, c.stratum, c.reference_id,
         CASE WHEN c.outcome = 'kiss_of_death' OR c.stratum = 1 THEN
           (SELECT string_agg(CASE WHEN o BETWEEN 32 AND 126 THEN chr(o)
                                   WHEN o = 0 THEN ''
                                   ELSE '?' END, '' ORDER BY i)
            FROM (SELECT i, ((c.reference_id >> (24 - 8 * i)) & 255)::integer AS o
                  FROM generate_series(0, 3) i) octets)
         ELSE format('%s.%s.%s.%s', c.reference_id >> 24, (c.reference_id >> 16) & 255,
                     (c.reference_id >> 8) & 255, c.reference_id & 255)
         END AS reference
  FROM store.clock_checks c
  WHERE c.reference_id IS NOT NULL;

-- Per answered check, the NTP figures in seconds, exact: offset
-- ((t2 − t1) + (t3 − t4)) / 2, what to add to the collector's clock to get
-- the server's; delay (t4 − t1) − (t3 − t2), the round trip less the server's
-- time; and error bound delay / 2, within which the true offset lies. t2 and
-- t3 are shown as timestamptz too, cut to microseconds.
-- contract: central/test/clock.sql
CREATE VIEW store.clock_offsets AS
  SELECT c.collector_id, c.t1,
         timestamptz 'epoch' + (floor(c.t2_unix * 1000000) * 0.000001 || ' seconds')::interval AS t2,
         timestamptz 'epoch' + (floor(c.t3_unix * 1000000) * 0.000001 || ' seconds')::interval AS t3,
         c.t4, c.t2_unix, c.t3_unix,
         trim_scale(((c.t2_unix - t.t1_unix) + (c.t3_unix - t.t4_unix)) * 0.5) AS offset_seconds,
         trim_scale((t.t4_unix - t.t1_unix) - (c.t3_unix - c.t2_unix)) AS delay_seconds,
         trim_scale(((t.t4_unix - t.t1_unix) - (c.t3_unix - c.t2_unix)) * 0.5)
           AS error_bound_seconds,
         c.server, c.address, c.stratum, c.leap, c.reference_id, r.reference, c.trigger,
         c.batch_id
  FROM store.clock_checks c
  CROSS JOIN LATERAL (SELECT extract(epoch FROM c.t1) AS t1_unix,
                             extract(epoch FROM c.t4) AS t4_unix) t
  JOIN store.clock_check_references r USING (collector_id, t1)
  WHERE c.outcome = 'answered';

-- Per upload, the fallback reference: the store's clock on arrival against
-- the collector's when it sent. One-sided: the batch was in transit for an
-- unknown time, so the collector's offset (as in store.clock_offsets) is at
-- most received_at − sent_at, never known to be that.
-- contract: central/test/clock.sql
CREATE VIEW store.upload_clock_offsets AS
  SELECT u.collector_id, u.upload_id, u.batch_id, u.sent_at, u.received_at,
         trim_scale(extract(epoch FROM u.received_at) - extract(epoch FROM u.sent_at))
           AS offset_at_most_seconds
  FROM store.uploads u;

COMMENT ON COLUMN store.upload_clock_offsets.offset_at_most_seconds IS 'An upper bound only: the true offset is this less the unknown transit time.';

-- Per endpoint (collector, host, port), UTC day and bucket version, every
-- meter's entries for the day merged, as store.latency_meter_days merges a
-- meter's.
-- contract: central/test/latency.sql
CREATE VIEW store.latency_endpoint_days AS
  WITH merged AS (
    SELECT d.collector_id, d.endpoint_host, d.endpoint_port, d.day, d.buckets_version, b.i,
           sum(b.n) AS n, count(*) AS entries, count(DISTINCT d.unit_id) AS meters,
           sum(d.retries) AS retries,
           sum(d.timeouts) AS timeouts, max(d.max_ms) AS max_ms
    FROM store.latency_days d
    CROSS JOIN LATERAL unnest(d.buckets) WITH ORDINALITY b(n, i)
    GROUP BY d.collector_id, d.endpoint_host, d.endpoint_port, d.day, d.buckets_version, b.i
  ),
  ranked AS (
    SELECT m.*, v.bounds_ms[m.i] AS upper_ms,
           sum(m.n) OVER (PARTITION BY m.collector_id, m.endpoint_host, m.endpoint_port, m.day,
                                       m.buckets_version ORDER BY m.i) AS through,
           sum(m.n) OVER (PARTITION BY m.collector_id, m.endpoint_host, m.endpoint_port, m.day,
                                       m.buckets_version) AS answered
    FROM merged m
    JOIN store.latency_bucket_versions v ON v.version = m.buckets_version
  ),
  figures AS (
    SELECT collector_id, endpoint_host, endpoint_port, day, buckets_version,
           max(entries) AS entries, max(meters) AS meters, max(answered) AS answered,
           max(retries) AS retries, max(timeouts) AS timeouts, max(max_ms) AS max_ms,
           min(upper_ms) FILTER (WHERE through >= div(answered * 50 + 99, 100)) AS p50,
           min(upper_ms) FILTER (WHERE through >= div(answered * 90 + 99, 100)) AS p90,
           min(upper_ms) FILTER (WHERE through >= div(answered * 99 + 99, 100)) AS p99
    FROM ranked
    GROUP BY collector_id, endpoint_host, endpoint_port, day, buckets_version
  )
  SELECT collector_id, endpoint_host, endpoint_port, day, buckets_version, entries, meters,
         answered::bigint AS answered,
         retries::bigint AS retries, timeouts::bigint AS timeouts,
         CASE WHEN answered > 0 THEN least(p50, max_ms) END AS p50_ms,
         CASE WHEN answered > 0 THEN least(p90, max_ms) END AS p90_ms,
         CASE WHEN answered > 0 THEN least(p99, max_ms) END AS p99_ms,
         max_ms
  FROM figures;

-- Readings with no answered check by their collector within 48 hours of
-- them, before or after, by the collector's clock (read_at and t1 both are):
-- nothing places them in true time. With the nearest answered checks either
-- side, if any.
-- contract: central/test/clock.sql
CREATE VIEW store.ungrounded_readings AS
  SELECT r.meter_serial, r.register_key, r.read_at, r.collector_id, r.batch_id,
         (SELECT max(c.t1) FROM store.clock_checks c
          WHERE c.collector_id = r.collector_id AND c.outcome = 'answered' AND c.t1 <= r.read_at)
           AS previous_check_at,
         (SELECT min(c.t1) FROM store.clock_checks c
          WHERE c.collector_id = r.collector_id AND c.outcome = 'answered' AND c.t1 > r.read_at)
           AS next_check_at
  FROM store.readings r
  WHERE NOT EXISTS (
    SELECT FROM store.clock_checks c
    WHERE c.collector_id = r.collector_id AND c.outcome = 'answered'
      AND c.t1 BETWEEN r.read_at - interval '48 hours' AND r.read_at + interval '48 hours');

-- Per cumulative reading lower than the cumulative reading before it of the
-- same serial and register: both readings, each with its unit, its batch's
-- clock claim (clock_source, clock_last_sync_at) and whether an answered
-- clock check grounds it (not in store.ungrounded_readings). Values are
-- compared exactly, Wh against kWh by ×1000 (varh, kvarh alike). A drop is
-- suspect where neither reading is grounded: then it may be the clock, not
-- the meter. The OS's claim is shown, never judged by.
-- contract: central/test/energy.sql
CREATE VIEW store.energy_drops AS
  SELECT r.meter_serial, r.register_key,
         p.read_at AS previous_read_at, p.value AS previous_value, p.unit AS previous_unit,
         p.collector_id AS previous_collector_id, p.batch_id AS previous_batch_id,
         p.clock_source AS previous_clock_source,
         p.clock_last_sync_at AS previous_clock_last_sync_at,
         p.grounded AS previous_grounded,
         r.read_at, r.value, rr.unit, r.collector_id, r.batch_id,
         rb.clock_source, rb.clock_last_sync_at, g.grounded,
         NOT (p.grounded OR g.grounded) AS suspect
  FROM store.readings r
  JOIN store.profile_registers rr
    ON (rr.profile, rr.version, rr.register_key) = (r.profile, r.profile_version, r.register_key)
  JOIN store.batches rb ON rb.batch_id = r.batch_id
  CROSS JOIN LATERAL (
    SELECT NOT EXISTS (SELECT FROM store.ungrounded_readings u
                       WHERE (u.meter_serial, u.register_key, u.read_at)
                             = (r.meter_serial, r.register_key, r.read_at)) AS grounded
  ) g
  CROSS JOIN LATERAL (
    SELECT q.read_at, q.value, qr.unit, q.collector_id, q.batch_id, qb.clock_source,
           qb.clock_last_sync_at,
           NOT EXISTS (SELECT FROM store.ungrounded_readings u
                       WHERE (u.meter_serial, u.register_key, u.read_at)
                             = (q.meter_serial, q.register_key, q.read_at)) AS grounded
    FROM store.readings q
    JOIN store.profile_registers qr
      ON (qr.profile, qr.version, qr.register_key) = (q.profile, q.profile_version, q.register_key)
    JOIN store.batches qb ON qb.batch_id = q.batch_id
    WHERE q.meter_serial = r.meter_serial AND q.register_key = r.register_key
      AND q.read_at < r.read_at AND qr.kind = 'cumulative'
    ORDER BY q.read_at DESC
    LIMIT 1
  ) p
  WHERE rr.kind = 'cumulative'
    AND r.value * CASE WHEN rr.unit IN ('kWh', 'kvarh') THEN 1000 ELSE 1 END
        < p.value * CASE WHEN p.unit IN ('kWh', 'kvarh') THEN 1000 ELSE 1 END;

-- Per meter (collector, endpoint, unit), UTC day and bucket version, every
-- poller's entries for that day merged: a restart's part of a day with the
-- part before it.
-- contract: central/test/latency.sql
CREATE VIEW store.latency_meter_days AS
  WITH merged AS (
    SELECT d.collector_id, d.endpoint_host, d.endpoint_port, d.unit_id, d.day,
           d.buckets_version, b.i, sum(b.n) AS n, count(*) AS entries, sum(d.retries) AS retries,
           sum(d.timeouts) AS timeouts, max(d.max_ms) AS max_ms
    FROM store.latency_days d
    CROSS JOIN LATERAL unnest(d.buckets) WITH ORDINALITY b(n, i)
    GROUP BY d.collector_id, d.endpoint_host, d.endpoint_port, d.unit_id, d.day,
             d.buckets_version, b.i
  ),
  ranked AS (
    SELECT m.*, v.bounds_ms[m.i] AS upper_ms,
           sum(m.n) OVER (PARTITION BY m.collector_id, m.endpoint_host, m.endpoint_port,
                                       m.unit_id, m.day, m.buckets_version ORDER BY m.i)
             AS through,
           sum(m.n) OVER (PARTITION BY m.collector_id, m.endpoint_host, m.endpoint_port,
                                       m.unit_id, m.day, m.buckets_version) AS answered
    FROM merged m
    JOIN store.latency_bucket_versions v ON v.version = m.buckets_version
  ),
  figures AS (
    SELECT collector_id, endpoint_host, endpoint_port, unit_id, day, buckets_version,
           max(entries) AS entries, max(answered) AS answered,
           max(retries) AS retries, max(timeouts) AS timeouts, max(max_ms) AS max_ms,
           min(upper_ms) FILTER (WHERE through >= div(answered * 50 + 99, 100)) AS p50,
           min(upper_ms) FILTER (WHERE through >= div(answered * 90 + 99, 100)) AS p90,
           min(upper_ms) FILTER (WHERE through >= div(answered * 99 + 99, 100)) AS p99
    FROM ranked
    GROUP BY collector_id, endpoint_host, endpoint_port, unit_id, day, buckets_version
  )
  SELECT collector_id, endpoint_host, endpoint_port, unit_id, day, buckets_version, entries,
         answered::bigint AS answered,
         retries::bigint AS retries, timeouts::bigint AS timeouts,
         CASE WHEN answered > 0 THEN least(p50, max_ms) END AS p50_ms,
         CASE WHEN answered > 0 THEN least(p90, max_ms) END AS p90_ms,
         CASE WHEN answered > 0 THEN least(p99, max_ms) END AS p99_ms,
         max_ms
  FROM figures;


-- ==== registry ==============================================================

-- How an endpoint frames Modbus: TCP, or RTU over TCP.
CREATE TYPE registry.framing AS ENUM (
    'tcp',
    'rtu_over_tcp'
);

CREATE TABLE registry.endpoints (
  id text PRIMARY KEY CHECK (id ~ '^[a-z][a-z0-9_]{0,39}$'),
  created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE registry.endpoints IS 'One row per endpoint: an IP address and port in front of an RS-485 chain.';

-- An endpoint's settings from valid_from; of rows sharing a valid_from, the
-- one recorded last holds (registry.endpoint_history). Polling settings and
-- ranges as in alavi/lib/alavi/config/endpoint.ex. Only ever added to, by the
-- admin functions.
-- contract: central/test/registry.sql
CREATE TABLE registry.endpoint_versions (
    version_id bigint NOT NULL,
    endpoint_id text NOT NULL,
    valid_from timestamp with time zone NOT NULL,
    recorded_at timestamp with time zone DEFAULT now() NOT NULL,
    in_service boolean NOT NULL,
    collector_id text NOT NULL,
    host text NOT NULL,
    port integer NOT NULL,
    framing registry.framing NOT NULL,
    polled_by_other_system boolean NOT NULL,
    timeout_ms integer NOT NULL,
    max_timeouts integer,
    retries integer NOT NULL,
    busy_backoff_ms integer NOT NULL,
    reconnect_backoff_min_ms integer NOT NULL,
    reconnect_backoff_max_ms integer NOT NULL,
    interval_ms integer NOT NULL,
    copy boolean NOT NULL,
    retry_ms integer NOT NULL,
    CONSTRAINT endpoint_versions_busy_backoff_ms_check CHECK (((busy_backoff_ms >= 0) AND (busy_backoff_ms <= 86400000))),
    CONSTRAINT endpoint_versions_check CHECK (((reconnect_backoff_max_ms >= reconnect_backoff_min_ms) AND (reconnect_backoff_max_ms <= 86400000))),
    CONSTRAINT endpoint_versions_host_check CHECK ((host ~ '^[^[:space:][:cntrl:]]{1,253}$'::text)),
    CONSTRAINT endpoint_versions_interval_ms_check CHECK (((interval_ms >= 1) AND (interval_ms <= 86400000))),
    CONSTRAINT endpoint_versions_max_timeouts_check CHECK (((max_timeouts >= 1) AND (max_timeouts <= 100))),
    CONSTRAINT endpoint_versions_port_check CHECK (((port >= 1) AND (port <= 65535))),
    CONSTRAINT endpoint_versions_reconnect_backoff_min_ms_check CHECK (((reconnect_backoff_min_ms >= 1) AND (reconnect_backoff_min_ms <= 86400000))),
    CONSTRAINT endpoint_versions_retries_check CHECK (((retries >= 0) AND (retries <= 10))),
    CONSTRAINT endpoint_versions_retry_ms_check CHECK (((retry_ms >= 1) AND (retry_ms <= 86400000))),
    CONSTRAINT endpoint_versions_timeout_ms_check CHECK (((timeout_ms >= 1) AND (timeout_ms <= 86400000))),
    CONSTRAINT endpoint_versions_valid_from_check CHECK (isfinite(valid_from)),
    CONSTRAINT interval_divides_a_day CHECK (
CASE
    WHEN (interval_ms > 0) THEN ((86400000 % interval_ms) = 0)
    ELSE NULL::boolean
END),
    CONSTRAINT max_timeouts_for_tcp_only CHECK (((framing = 'tcp'::registry.framing) = (max_timeouts IS NOT NULL)))
);

COMMENT ON COLUMN registry.endpoint_versions.polled_by_other_system IS 'Another system (the existing monitoring server) polls this endpoint; collectors never connect to it.';

COMMENT ON COLUMN registry.endpoint_versions.copy IS 'Copy its meters'' stored entries within its collector''s copy window.';

COMMENT ON COLUMN registry.endpoint_versions.retry_ms IS 'How soon a meter that gave no reading in a round is read again, until it answers; a target''s own retry_ms takes its place.';

ALTER TABLE registry.endpoint_versions ALTER COLUMN version_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME registry.endpoint_versions_version_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE ONLY registry.endpoint_versions
    ADD CONSTRAINT endpoint_versions_pkey PRIMARY KEY (version_id);

CREATE INDEX endpoint_versions_endpoint_id_valid_from_idx ON registry.endpoint_versions USING btree (endpoint_id, valid_from);

ALTER TABLE ONLY registry.endpoint_versions
    ADD CONSTRAINT endpoint_versions_collector_id_fkey FOREIGN KEY (collector_id) REFERENCES store.collectors(id);

ALTER TABLE ONLY registry.endpoint_versions
    ADD CONSTRAINT endpoint_versions_endpoint_id_fkey FOREIGN KEY (endpoint_id) REFERENCES registry.endpoints(id);

-- contract: central/test/registry.sql
CREATE TABLE registry.meters (
    serial text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT meters_serial_check CHECK (((serial ~ '^[!-~]([ -~]*[!-~])?$'::text) AND (length(serial) <= 100)))
);

COMMENT ON TABLE registry.meters IS 'One row per meter, by the serial its readings carry.';

ALTER TABLE ONLY registry.meters
    ADD CONSTRAINT meters_pkey PRIMARY KEY (serial);

-- A meter replaced by another at its target, as admin.swap_meter records it.
-- contract: central/test/registry.sql
CREATE TABLE registry.meter_swaps (
  old_serial text NOT NULL REFERENCES registry.meters (serial),
  new_serial text NOT NULL REFERENCES registry.meters (serial),
  swapped_at timestamptz NOT NULL CHECK (isfinite(swapped_at)),
  recorded_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (old_serial, new_serial, swapped_at),
  CHECK (old_serial <> new_serial)
);

-- What the health views judge by; the row set last holds.
-- contract: central/test/health.sql
CREATE TABLE registry.health_thresholds (
    version_id bigint NOT NULL,
    set_at timestamp with time zone DEFAULT now() NOT NULL,
    collector_silent_after interval NOT NULL,
    meter_silent_intervals numeric NOT NULL,
    backlog_near_capacity numeric NOT NULL,
    lookback interval NOT NULL,
    endpoint_error_rate numeric NOT NULL,
    snapshot_missed_margin interval NOT NULL,
    history_behind_after interval NOT NULL,
    snapshot_behind_after_elite_500 interval NOT NULL,
    load_survey_behind_after_elite_440 interval NOT NULL,
    load_survey_behind_after_elite_500 interval NOT NULL,
    meter_clock_step_after interval NOT NULL,
    meter_clock_far_after interval NOT NULL,
    copy_failing_interval interval NOT NULL,
    CONSTRAINT health_thresholds_backlog_near_capacity_check CHECK (((backlog_near_capacity > (0)::numeric) AND (backlog_near_capacity <= (1)::numeric))),
    CONSTRAINT health_thresholds_collector_silent_after_check CHECK ((collector_silent_after > '00:00:00'::interval)),
    CONSTRAINT health_thresholds_copy_failing_interval_check CHECK ((copy_failing_interval > '00:00:00'::interval)),
    CONSTRAINT health_thresholds_endpoint_error_rate_check CHECK (((endpoint_error_rate > (0)::numeric) AND (endpoint_error_rate <= (1)::numeric))),
    CONSTRAINT health_thresholds_history_behind_after_check CHECK ((history_behind_after > '00:00:00'::interval)),
    CONSTRAINT health_thresholds_load_survey_behind_after_elite_440_check CHECK ((load_survey_behind_after_elite_440 > '00:00:00'::interval)),
    CONSTRAINT health_thresholds_load_survey_behind_after_elite_500_check CHECK ((load_survey_behind_after_elite_500 > '00:00:00'::interval)),
    CONSTRAINT health_thresholds_lookback_check CHECK ((lookback > '00:00:00'::interval)),
    CONSTRAINT health_thresholds_meter_clock_far_after_check CHECK ((meter_clock_far_after > '00:00:00'::interval)),
    CONSTRAINT health_thresholds_meter_clock_step_after_check CHECK ((meter_clock_step_after > '00:00:00'::interval)),
    CONSTRAINT health_thresholds_meter_silent_intervals_check CHECK ((meter_silent_intervals >= (1)::numeric)),
    CONSTRAINT health_thresholds_snapshot_behind_after_elite_500_check CHECK ((snapshot_behind_after_elite_500 > '00:00:00'::interval)),
    CONSTRAINT health_thresholds_snapshot_missed_margin_check CHECK ((snapshot_missed_margin > '00:00:00'::interval))
);

ALTER TABLE registry.health_thresholds ALTER COLUMN version_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME registry.health_thresholds_version_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE ONLY registry.health_thresholds
    ADD CONSTRAINT health_thresholds_pkey PRIMARY KEY (version_id);

-- contract: central/test/registry.sql
CREATE TABLE registry.targets (
  endpoint_id text NOT NULL REFERENCES registry.endpoints (id),
  unit_id smallint NOT NULL CHECK (unit_id BETWEEN 1 AND 247),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (endpoint_id, unit_id)
);

COMMENT ON TABLE registry.targets IS 'One row per place to poll: a unit id on an endpoint''s chain, whatever meter answers there.';

-- Where a meter is placed (target) from valid_from; of rows sharing a
-- valid_from, the one recorded last holds (registry.meter_history).
-- contract: central/test/registry.sql
CREATE TABLE registry.meter_versions (
  version_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  serial text NOT NULL REFERENCES registry.meters (serial),
  valid_from timestamptz NOT NULL CHECK (isfinite(valid_from)),
  recorded_at timestamptz NOT NULL DEFAULT now(),
  in_service boolean NOT NULL,
  endpoint_id text NOT NULL,
  unit_id smallint NOT NULL,
  FOREIGN KEY (endpoint_id, unit_id) REFERENCES registry.targets (endpoint_id, unit_id)
);

COMMENT ON COLUMN registry.meter_versions.in_service IS 'false from the meter''s retirement on; the target then says where it was last.';

CREATE INDEX meter_versions_endpoint_id_unit_id_idx ON registry.meter_versions USING btree (endpoint_id, unit_id);

CREATE INDEX meter_versions_serial_valid_from_idx ON registry.meter_versions USING btree (serial, valid_from);

-- A target's profile and intervals from valid_from; of rows sharing a
-- valid_from, the one recorded last holds (registry.target_history). An
-- interval divides a day, so poll slots fall on the same times every day.
-- contract: central/test/registry.sql
CREATE TABLE registry.target_versions (
    version_id bigint NOT NULL,
    endpoint_id text NOT NULL,
    unit_id smallint NOT NULL,
    valid_from timestamp with time zone NOT NULL,
    recorded_at timestamp with time zone DEFAULT now() NOT NULL,
    in_service boolean NOT NULL,
    profile text NOT NULL,
    interval_ms integer,
    retry_ms integer,
    CONSTRAINT interval_divides_a_day CHECK (
CASE
    WHEN (interval_ms > 0) THEN ((86400000 % interval_ms) = 0)
    ELSE NULL::boolean
END),
    CONSTRAINT target_versions_interval_ms_check CHECK (((interval_ms >= 1) AND (interval_ms <= 86400000))),
    CONSTRAINT target_versions_profile_check CHECK ((profile ~ '^[a-z][a-z0-9_]{0,39}$'::text)),
    CONSTRAINT target_versions_retry_ms_check CHECK (((retry_ms >= 1) AND (retry_ms <= 86400000))),
    CONSTRAINT target_versions_valid_from_check CHECK (isfinite(valid_from))
);

COMMENT ON COLUMN registry.target_versions.in_service IS 'false from the target''s retirement on; the other columns then say how it was last polled.';

COMMENT ON COLUMN registry.target_versions.interval_ms IS 'How often the unit is read; NULL means its endpoint''s interval, as in the polling config.';

COMMENT ON COLUMN registry.target_versions.retry_ms IS 'How soon the unit is read again after a round that gave no reading; NULL means its endpoint''s, as in the polling config.';

ALTER TABLE registry.target_versions ALTER COLUMN version_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME registry.target_versions_version_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE ONLY registry.target_versions
    ADD CONSTRAINT target_versions_pkey PRIMARY KEY (version_id);

CREATE INDEX target_versions_endpoint_id_unit_id_valid_from_idx ON registry.target_versions USING btree (endpoint_id, unit_id, valid_from);

ALTER TABLE ONLY registry.target_versions
    ADD CONSTRAINT target_versions_endpoint_id_unit_id_fkey FOREIGN KEY (endpoint_id, unit_id) REFERENCES registry.targets(endpoint_id, unit_id);

-- A collector's copy window, in its local wall-clock time, from valid_from;
-- of rows sharing a valid_from, the one recorded last holds. Times are whole
-- minutes, as the polling config carries them; an end before the start
-- crosses midnight.
-- contract: central/test/config.sql, central/test/collector_config.sql
CREATE TABLE registry.copy_window_versions (
  version_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  collector_id text NOT NULL REFERENCES store.collectors (id),
  valid_from timestamptz NOT NULL CHECK (isfinite(valid_from)),
  recorded_at timestamptz NOT NULL DEFAULT now(),
  start_time time NOT NULL CHECK (start_time < time '24:00' AND extract(second FROM start_time) = 0),
  end_time time NOT NULL CHECK (end_time < time '24:00' AND extract(second FROM end_time) = 0),
  CHECK (start_time <> end_time)
);

CREATE INDEX copy_window_versions_collector_id_valid_from_idx ON registry.copy_window_versions USING btree (collector_id, valid_from);

-- RFC 8785 (JCS) for a polling config: no whitespace, keys sorted by their
-- bytes, jsonb's own text for strings (escaped as JCS does), integers,
-- booleans and null.
-- contract: central/test/collector_config.sql
CREATE FUNCTION registry.canonical_json(v jsonb) RETURNS text
    LANGUAGE plpgsql IMMUTABLE STRICT
    AS $$
BEGIN
  RETURN CASE jsonb_typeof(v)
    WHEN 'object' THEN
      '{' || coalesce((SELECT string_agg(to_jsonb(k)::text || ':' || registry.canonical_json(x), ','
                                         ORDER BY k COLLATE "C")
                       FROM jsonb_each(v) e(k, x)), '') || '}'
    WHEN 'array' THEN
      '[' || coalesce((SELECT string_agg(registry.canonical_json(x), ',' ORDER BY i)
                       FROM jsonb_array_elements(v) WITH ORDINALITY a(x, i)), '') || ']'
    ELSE v::text
  END;
END
$$;

-- Checked after every admin change, over the whole history, so a back-dated
-- row is judged against what follows it. Raises exclusion_violation (23P01).
-- contract: central/test/registry.sql
CREATE FUNCTION registry.check_history() RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
  conflict text;
BEGIN
  SELECT format('endpoints %s and %s are both %s:%s on collector %s from %s',
                a.endpoint_id, b.endpoint_id, a.host, a.port, a.collector_id,
                greatest(lower(a.period), lower(b.period)))
    INTO conflict
    FROM registry.endpoint_history a
    JOIN registry.endpoint_history b
      ON a.collector_id = b.collector_id AND a.host = b.host AND a.port = b.port
     AND a.endpoint_id < b.endpoint_id AND a.period && b.period
   WHERE a.in_service AND b.in_service
   LIMIT 1;
  IF conflict IS NULL THEN
    SELECT format('meters %s and %s are both at %s unit %s from %s',
                  a.serial, b.serial, a.endpoint_id, a.unit_id,
                  greatest(lower(a.period), lower(b.period)))
      INTO conflict
      FROM registry.meter_history a
      JOIN registry.meter_history b
        ON a.endpoint_id = b.endpoint_id AND a.unit_id = b.unit_id
       AND a.serial < b.serial AND a.period && b.period
     WHERE a.in_service AND b.in_service
     LIMIT 1;
  END IF;
  IF conflict IS NULL THEN
    SELECT format('%s unit %s is in service from %s, when its endpoint is not',
                  g.endpoint_id, g.unit_id, lower(g.period))
      INTO conflict
      FROM registry.target_history g
     WHERE g.in_service
       AND (lower(g.period) < (SELECT min(e.valid_from) FROM registry.endpoint_versions e
                               WHERE e.endpoint_id = g.endpoint_id)
            OR EXISTS (SELECT FROM registry.endpoint_history e
                       WHERE e.endpoint_id = g.endpoint_id AND NOT e.in_service
                         AND e.period && g.period))
     LIMIT 1;
  END IF;
  IF conflict IS NULL THEN
    SELECT format('meter %s is in service at %s unit %s from %s, when the target is not',
                  m.serial, m.endpoint_id, m.unit_id, lower(m.period))
      INTO conflict
      FROM registry.meter_history m
     WHERE m.in_service
       AND (lower(m.period) < coalesce((SELECT min(g.valid_from) FROM registry.target_versions g
                                        WHERE (g.endpoint_id, g.unit_id)
                                              = (m.endpoint_id, m.unit_id)),
                                       'infinity')
            OR EXISTS (SELECT FROM registry.target_history g
                       WHERE (g.endpoint_id, g.unit_id) = (m.endpoint_id, m.unit_id)
                         AND NOT g.in_service AND g.period && m.period))
     LIMIT 1;
  END IF;
  IF conflict IS NOT NULL THEN
    RAISE EXCEPTION 'registry change refused: %', conflict
      USING ERRCODE = 'exclusion_violation',
            HINT = 'Move or retire what is in the way first, from the same time.';
  END IF;
END
$$;

-- A collector's polling config as of now(): its endpoints in service, by
-- host and port, each with its copy and retry_ms, and its targets in service,
-- by unit id, with the serial of the meter placed at each when there is one.
-- A target with no interval or retry_ms of its own leaves it out, so its
-- endpoint's applies. The collector's copy window in force now, left out when
-- it has none. An endpoint with no target in service has no meters, and a
-- collector with no endpoint in service none: served as they are, for the
-- collector to refuse.
-- contract: central/test/collector_config.sql
CREATE FUNCTION registry.collector_config(collector text) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
  SELECT jsonb_strip_nulls(jsonb_build_object(
    'schema_version', 1,
    'copy_window',
      (SELECT jsonb_build_object('start', to_char(w.start_time, 'HH24:MI'),
                                 'end', to_char(w.end_time, 'HH24:MI'))
       FROM registry.copy_window_history w
       WHERE w.collector_id = collector AND w.period @> now()),
    'endpoints', coalesce(jsonb_agg(x.endpoint ORDER BY x.host COLLATE "C", x.port), '[]')))
  FROM (
    SELECT e.host, e.port, jsonb_build_object(
             'host', e.host, 'port', e.port, 'framing', e.framing,
             'max_timeouts', e.max_timeouts,
             'polled_by_other_system', e.polled_by_other_system,
             'timeout_ms', e.timeout_ms, 'retries', e.retries,
             'busy_backoff_ms', e.busy_backoff_ms,
             'reconnect_backoff_ms', jsonb_build_object('min', e.reconnect_backoff_min_ms,
                                                        'max', e.reconnect_backoff_max_ms),
             'interval_ms', e.interval_ms,
             'retry_ms', e.retry_ms,
             'copy', e.copy,
             'meters', coalesce(
               (SELECT jsonb_agg(jsonb_build_object('unit_id', g.unit_id, 'serial', m.serial,
                                                    'profile', g.profile,
                                                    'interval_ms', g.interval_ms,
                                                    'retry_ms', g.retry_ms)
                                 ORDER BY g.unit_id)
                FROM registry.target_history g
                LEFT JOIN registry.meter_history m
                  ON (m.endpoint_id, m.unit_id) = (g.endpoint_id, g.unit_id)
                 AND m.in_service AND m.period @> now()
                WHERE g.endpoint_id = e.endpoint_id AND g.in_service AND g.period @> now()),
               '[]')) AS endpoint
    FROM registry.endpoint_history e
    WHERE e.collector_id = collector AND e.in_service AND e.period @> now()
  ) x
$$;

-- contract/fixtures/config.v1.digests.json: SHA-256 of the canonical
-- encoding's UTF-8 bytes, in lowercase hex.
-- contract: central/test/collector_config.sql
CREATE FUNCTION registry.config_digest(document jsonb) RETURNS text
    LANGUAGE sql IMMUTABLE STRICT
    AS $$
  SELECT encode(sha256(convert_to(registry.canonical_json(document), 'UTF8')), 'hex')
$$;

-- The registry is only added to: every registry table has this trigger for
-- UPDATE and DELETE, and refuse_truncate for TRUNCATE.
-- contract: central/test/registry.sql
CREATE FUNCTION registry.refuse_change() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION '% on %.% refused: registry history is never changed or deleted',
    TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME
    USING HINT = 'A change or correction is a new row, through the admin functions.';
END
$$;

-- Each table listed refuses UPDATE, DELETE and TRUNCATE (registry.refuse_change).
DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'endpoints',
    'endpoint_versions',
    'meters',
    'meter_swaps',
    'health_thresholds',
    'targets',
    'meter_versions',
    'target_versions',
    'copy_window_versions'
  ] LOOP
    EXECUTE format(
      'CREATE TRIGGER refuse_change BEFORE UPDATE OR DELETE ON registry.%I
         FOR EACH ROW EXECUTE FUNCTION registry.refuse_change()', t);
    EXECUTE format(
      'CREATE TRIGGER refuse_truncate BEFORE TRUNCATE ON registry.%I
         FOR EACH STATEMENT EXECUTE FUNCTION registry.refuse_change()', t);
  END LOOP;
END
$$;

-- Each endpoint's versions as periods: the row recorded last for a
-- valid_from, holding until the next valid_from.
CREATE VIEW registry.endpoint_history AS
  SELECT v.endpoint_id, v.valid_from, lead(v.valid_from) OVER w AS valid_to,
         tstzrange(v.valid_from, lead(v.valid_from) OVER w) AS period,
         v.in_service, v.collector_id, v.host, v.port, v.framing, v.polled_by_other_system,
         v.timeout_ms, v.max_timeouts, v.retries, v.busy_backoff_ms,
         v.reconnect_backoff_min_ms, v.reconnect_backoff_max_ms, v.interval_ms,
         v.version_id, v.recorded_at, v.copy, v.retry_ms
  FROM (
    SELECT DISTINCT ON (endpoint_id, valid_from) *
    FROM registry.endpoint_versions
    ORDER BY endpoint_id, valid_from, version_id DESC
  ) v
  WINDOW w AS (PARTITION BY v.endpoint_id ORDER BY v.valid_from);

-- Each target's versions as periods, as registry.endpoint_history.
CREATE VIEW registry.target_history AS
  SELECT v.endpoint_id, v.unit_id, v.valid_from, lead(v.valid_from) OVER w AS valid_to,
         tstzrange(v.valid_from, lead(v.valid_from) OVER w) AS period,
         v.in_service, v.profile, v.interval_ms, v.version_id, v.recorded_at, v.retry_ms
  FROM (
    SELECT DISTINCT ON (endpoint_id, unit_id, valid_from) *
    FROM registry.target_versions
    ORDER BY endpoint_id, unit_id, valid_from, version_id DESC
  ) v
  WINDOW w AS (PARTITION BY v.endpoint_id, v.unit_id ORDER BY v.valid_from);

-- Each meter's placements as periods, as registry.endpoint_history.
CREATE VIEW registry.meter_history AS
  SELECT v.serial, v.valid_from, lead(v.valid_from) OVER w AS valid_to,
         tstzrange(v.valid_from, lead(v.valid_from) OVER w) AS period,
         v.in_service, v.endpoint_id, v.unit_id, v.version_id, v.recorded_at
  FROM (
    SELECT DISTINCT ON (serial, valid_from) *
    FROM registry.meter_versions
    ORDER BY serial, valid_from, version_id DESC
  ) v
  WINDOW w AS (PARTITION BY v.serial ORDER BY v.valid_from);

-- Each collector's copy windows as periods, as registry.endpoint_history.
CREATE VIEW registry.copy_window_history AS
  SELECT v.collector_id, v.valid_from, lead(v.valid_from) OVER w AS valid_to,
         tstzrange(v.valid_from, lead(v.valid_from) OVER w) AS period,
         v.start_time, v.end_time, v.version_id, v.recorded_at
  FROM (
    SELECT DISTINCT ON (collector_id, valid_from) *
    FROM registry.copy_window_versions
    ORDER BY collector_id, valid_from, version_id DESC
  ) v
  WINDOW w AS (PARTITION BY v.collector_id ORDER BY v.valid_from);


-- ==== jobs ==================================================================

-- read_on_demand is requested by minkanakku_staff (jobs.request_job);
-- fill_copies by the operator (admin.request_fill).
CREATE TYPE jobs.kind AS ENUM (
    'read_on_demand',
    'fill_copies'
);

-- A request's state, derived in jobs.request_status, never stored.
CREATE TYPE jobs.state AS ENUM (
    'pending',
    'answered',
    'expired'
);

-- A job asked of a collector. Requests and their links to what came of them
-- are a record: rows are only ever added (jobs.refuse_change).
-- contract: central/test/requests.sql
CREATE TABLE jobs.requests (
  request_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  collector_id text NOT NULL REFERENCES store.collectors (id),
  kind jobs.kind NOT NULL,
  requester text NOT NULL CHECK (requester ~ '^[^[:cntrl:]]{1,200}$'),
  requested_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  CHECK (expires_at > requested_at)
);

COMMENT ON COLUMN jobs.requests.requester IS 'Who asked, as an opaque reference minkanakku resolves; nothing about the person.';

COMMENT ON COLUMN jobs.requests.expires_at IS 'After this, a request not yet answered is no longer offered to its collector.';

CREATE INDEX requests_collector_id_expires_at_idx ON jobs.requests USING btree (collector_id, expires_at);

-- The meters a request names, by serial.
CREATE TABLE jobs.request_meters (
  request_id uuid NOT NULL REFERENCES jobs.requests (request_id),
  serial text NOT NULL REFERENCES registry.meters (serial),
  PRIMARY KEY (request_id, serial)
);

-- A reading a collector sent for a request, by the readings key. The reading
-- itself is stored as any other; this row is the link, so the raw row is
-- never touched, and a resend links nothing twice.
CREATE TABLE jobs.request_readings (
  request_id uuid NOT NULL REFERENCES jobs.requests (request_id),
  meter_serial text NOT NULL,
  register_key text NOT NULL,
  read_at timestamptz NOT NULL,
  batch_id uuid NOT NULL REFERENCES store.batches (batch_id),
  linked_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (request_id, meter_serial, register_key, read_at)
);

-- A missed read a collector sent for a request, by the missed reads key.
CREATE TABLE jobs.request_missed_reads (
  request_id uuid NOT NULL REFERENCES jobs.requests (request_id),
  collector_id text NOT NULL REFERENCES store.collectors (id),
  endpoint_host text NOT NULL,
  endpoint_port integer NOT NULL,
  unit_id smallint NOT NULL,
  register_key text NOT NULL,
  read_at timestamptz NOT NULL,
  batch_id uuid NOT NULL REFERENCES store.batches (batch_id),
  linked_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (request_id, collector_id, endpoint_host, endpoint_port, unit_id, register_key,
               read_at)
);

-- A fill request's range, in the meters' own clock (local time, no zone,
-- to the second): entries stamped from from_time, before to_time.
-- contract: central/test/fills.sql
CREATE TABLE jobs.request_fills (
  request_id uuid PRIMARY KEY REFERENCES jobs.requests (request_id),
  from_time timestamp NOT NULL,
  to_time timestamp NOT NULL,
  CHECK (from_time < to_time),
  CHECK (date_trunc('second', from_time) = from_time AND date_trunc('second', to_time) = to_time)
);

-- The stores a fill request names.
CREATE TABLE jobs.request_fill_stores (
  request_id uuid NOT NULL REFERENCES jobs.request_fills (request_id),
  store store.stored_store NOT NULL,
  PRIMARY KEY (request_id, store)
);

-- A stored entry a collector sent for a fill request, by the stored entries
-- key. The entry is stored as any other, under the request it was first sent
-- for; this row is the link, so an entry copied again for a fill is linked
-- though the store already held it.
CREATE TABLE jobs.request_stored_entries (
  request_id uuid NOT NULL REFERENCES jobs.requests (request_id),
  meter_serial text NOT NULL,
  store store.stored_store NOT NULL,
  register_key text NOT NULL,
  meter_time timestamp NOT NULL,
  batch_id uuid NOT NULL REFERENCES store.batches (batch_id),
  linked_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (request_id, meter_serial, store, register_key, meter_time)
);

-- What a fill found, per meter and store the request named, as first sent.
-- gone_before NULL: the meter held entries older than the range's start.
CREATE TABLE jobs.request_fill_results (
  request_id uuid NOT NULL REFERENCES jobs.request_fills (request_id),
  meter_serial text NOT NULL,
  store store.stored_store NOT NULL,
  gone_before timestamp,
  finished_at timestamptz NOT NULL,
  endpoint_host text NOT NULL,
  endpoint_port integer NOT NULL,
  unit_id smallint NOT NULL,
  batch_id uuid NOT NULL REFERENCES store.batches (batch_id),
  linked_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (request_id, meter_serial, store),
  FOREIGN KEY (request_id, meter_serial) REFERENCES jobs.request_meters (request_id, serial),
  FOREIGN KEY (request_id, store) REFERENCES jobs.request_fill_stores (request_id, store)
);

COMMENT ON COLUMN jobs.request_fill_results.gone_before IS 'Entries of the range stamped before this were no longer on the meter; NULL when it held entries older than the range''s start.';

-- A checked batch's readings and missed reads that carry a request id, by
-- their keys; none when none do.
CREATE FUNCTION jobs.batch_links(b jsonb) RETURNS TABLE(request_id uuid, is_reading boolean, meter_serial text, endpoint_host text, endpoint_port integer, unit_id smallint, register_key text, read_at timestamp with time zone)
    LANGUAGE sql STABLE
    AS $$
  SELECT (r ->> 'request_id')::uuid, true, r ->> 'meter_serial', NULL, NULL, NULL,
         r ->> 'register_key', (r ->> 'timestamp')::timestamptz
  FROM jsonb_array_elements(b -> 'readings') r WHERE r ? 'request_id'
  UNION ALL
  SELECT (m ->> 'request_id')::uuid, false, NULL, m -> 'endpoint' ->> 'host',
         (m -> 'endpoint' ->> 'port')::numeric::integer, (m ->> 'unit_id')::numeric::smallint,
         m ->> 'register_key', (m ->> 'timestamp')::timestamptz
  FROM jsonb_array_elements(b -> 'missed_reads') m WHERE m ? 'request_id'
$$;

-- Link a checked batch's readings and missed reads that carry a request id to
-- the calling collector's request, once each, and notify request_answered for
-- each request that gained a link; the notice goes out when the batch
-- commits. Returns the request ids in the batch that are not the caller's
-- requests, on any event (a stored entry or fill result too), sorted, or
-- NULL: their events are stored as any other, unlinked.
-- contract: central/test/requests.sql, central/test/fills.sql
CREATE FUNCTION jobs.link_batch(b jsonb, caller text, batch uuid) RETURNS uuid[]
    LANGUAGE plpgsql
    AS $$
DECLARE
  unknown uuid[];
  notified bigint;
BEGIN
  SELECT array_agg(DISTINCT l.request_id ORDER BY l.request_id) INTO unknown
  FROM (SELECT l.request_id FROM jobs.batch_links(b) l
        UNION ALL
        SELECT e.request_id FROM store.batch_stored_entries(b) e WHERE e.request_id IS NOT NULL
        UNION ALL
        SELECT r.request_id FROM store.batch_fill_results(b) r) l
  WHERE NOT EXISTS (SELECT FROM jobs.requests q
                    WHERE q.request_id = l.request_id AND q.collector_id = caller);

  WITH ours AS (
    SELECT l.* FROM jobs.batch_links(b) l
    JOIN jobs.requests q ON q.request_id = l.request_id AND q.collector_id = caller
  ), readings AS (
    INSERT INTO jobs.request_readings (request_id, meter_serial, register_key, read_at, batch_id)
    SELECT o.request_id, o.meter_serial, o.register_key, o.read_at, batch
    FROM ours o WHERE o.is_reading
    ON CONFLICT DO NOTHING
    RETURNING request_id
  ), missed AS (
    INSERT INTO jobs.request_missed_reads
      (request_id, collector_id, endpoint_host, endpoint_port, unit_id, register_key, read_at,
       batch_id)
    SELECT o.request_id, caller, o.endpoint_host, o.endpoint_port, o.unit_id, o.register_key,
           o.read_at, batch
    FROM ours o WHERE NOT o.is_reading
    ON CONFLICT DO NOTHING
    RETURNING request_id
  ), linked AS (
    SELECT n.request_id, count(*) FILTER (WHERE n.is_reading) AS readings,
           count(*) FILTER (WHERE NOT n.is_reading) AS missed_reads
    FROM (SELECT r.request_id, true AS is_reading FROM readings r
          UNION ALL SELECT m.request_id, false FROM missed m) n
    GROUP BY n.request_id
  )
  SELECT count(*) INTO notified
  FROM (SELECT pg_notify('request_answered', jsonb_build_object(
                 'request_id', k.request_id, 'batch_id', batch,
                 'readings', k.readings, 'missed_reads', k.missed_reads)::text)
        FROM linked k) n;

  RETURN unknown;
END
$$;

-- Link a checked batch's stored entries and fill results to the calling
-- collector's fill request: an entry of a meter and store it named, stamped
-- in its range; a result of a meter and store it named, once (a resent
-- result is a duplicate, and the first stands). Returns the fill results'
-- counts: received, inserted, duplicate, and unlinked (not the caller's
-- request, or a meter or store it did not name).
-- contract: central/test/fills.sql
CREATE FUNCTION jobs.link_fills(b jsonb, caller text, batch uuid) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  received integer := coalesce(jsonb_array_length(b -> 'fill_results'), 0);
  inserted integer;
  duplicate integer;
BEGIN
  INSERT INTO jobs.request_stored_entries
    (request_id, meter_serial, store, register_key, meter_time, batch_id)
  SELECT e.request_id, e.meter_serial, e.store, e.register_key, e.meter_time, batch
  FROM store.batch_stored_entries(b) e
  JOIN jobs.requests q ON q.request_id = e.request_id AND q.collector_id = caller
  JOIN jobs.request_fills f ON f.request_id = e.request_id
  JOIN jobs.request_fill_stores s ON (s.request_id, s.store) = (e.request_id, e.store)
  JOIN jobs.request_meters m ON (m.request_id, m.serial) = (e.request_id, e.meter_serial)
  WHERE e.meter_time >= f.from_time AND e.meter_time < f.to_time
  ON CONFLICT DO NOTHING;

  SELECT count(*) INTO duplicate
  FROM store.batch_fill_results(b) r
  JOIN jobs.request_fill_results x USING (request_id, meter_serial, store)
  JOIN jobs.requests q ON q.request_id = r.request_id AND q.collector_id = caller;

  WITH added AS (
    INSERT INTO jobs.request_fill_results
      (request_id, meter_serial, store, gone_before, finished_at, endpoint_host, endpoint_port,
       unit_id, batch_id)
    SELECT r.*, batch
    FROM store.batch_fill_results(b) r
    JOIN jobs.requests q ON q.request_id = r.request_id AND q.collector_id = caller
    JOIN jobs.request_fill_stores s ON (s.request_id, s.store) = (r.request_id, r.store)
    JOIN jobs.request_meters m ON (m.request_id, m.serial) = (r.request_id, r.meter_serial)
    ON CONFLICT DO NOTHING
    RETURNING 1
  )
  SELECT count(*) INTO inserted FROM added;

  RETURN jsonb_build_object('received', received, 'inserted', inserted, 'duplicate', duplicate,
                            'unlinked', received - inserted - duplicate);
END
$$;

-- A collector's requests neither answered nor expired, oldest first, as the
-- ingest answer lists them; NULL when there are none. A fill also names its
-- stores and its range, as meter times.
CREATE FUNCTION jobs.pending(collector text) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
  SELECT jsonb_agg(jsonb_build_object(
           'request_id', q.request_id, 'kind', q.kind,
           'meters', (SELECT jsonb_agg(rm.serial ORDER BY rm.serial)
                      FROM jobs.request_meters rm WHERE rm.request_id = q.request_id),
           'requested_at', q.requested_at, 'expires_at', q.expires_at)
         || coalesce((SELECT jsonb_build_object(
                        'stores', (SELECT jsonb_agg(s.store ORDER BY s.store)
                                   FROM jobs.request_fill_stores s
                                   WHERE s.request_id = f.request_id),
                        'from', to_char(f.from_time, 'YYYY-MM-DD"T"HH24:MI:SS'),
                        'to', to_char(f.to_time, 'YYYY-MM-DD"T"HH24:MI:SS'))
                      FROM jobs.request_fills f WHERE f.request_id = q.request_id), '{}')
         ORDER BY q.requested_at, q.request_id)
  FROM jobs.request_status q
  WHERE q.collector_id = collector AND q.state = 'pending'
$$;

-- Requests are a record: every jobs table has this trigger for UPDATE and
-- DELETE, and refuse_truncate for TRUNCATE.
-- contract: central/test/requests.sql
CREATE FUNCTION jobs.refuse_change() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION '% on %.% refused: requests are a record and are never changed or deleted',
    TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME;
END
$$;

-- Ask a collector to read meters now, as minkanakku_staff. Inserts the request
-- and touches nothing else; minkanakku rings the collector's doorbell itself.
-- Each meter must be in service now on an endpoint in service now with that
-- collector, which no other system polls. Refused with 22023 otherwise. A
-- request not answered within an hour expires.
--   SELECT jobs.request_job(collector_id => 'pilot_01', kind => 'read_on_demand',
--     meters => ARRAY['…'], requester => '…');
-- contract: central/test/requests.sql
CREATE FUNCTION jobs.request_job(collector_id text, kind text, meters text[], requester text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $_$
#variable_conflict use_variable
DECLARE
  id uuid;
  strays text;
BEGIN
  IF kind IS DISTINCT FROM 'read_on_demand' THEN
    RAISE SQLSTATE '22023' USING
      MESSAGE = format('kind %s cannot be requested: only read_on_demand can',
        coalesce(kind, '(none)'));
  END IF;
  IF NOT EXISTS (SELECT FROM store.collectors c WHERE c.id = collector_id) THEN
    RAISE SQLSTATE '22023' USING
      MESSAGE = format('collector %s is not registered', collector_id);
  END IF;
  IF requester IS NULL OR requester !~ '^[^[:cntrl:]]{1,200}$' THEN
    RAISE SQLSTATE '22023' USING
      MESSAGE = 'requester must be 1 to 200 characters with no control characters';
  END IF;
  IF coalesce(cardinality(meters), 0) = 0 OR array_position(meters, NULL) IS NOT NULL
     OR cardinality(meters) <> (SELECT count(DISTINCT s) FROM unnest(meters) s) THEN
    RAISE SQLSTATE '22023' USING
      MESSAGE = 'meters must name at least one serial, each once, and no NULL';
  END IF;

  SELECT string_agg(s, ', ' ORDER BY s) INTO strays
  FROM unnest(meters) s
  WHERE NOT EXISTS (
    SELECT FROM registry.meter_history m
    JOIN registry.endpoint_history e ON e.endpoint_id = m.endpoint_id AND e.period @> now()
    WHERE m.serial = s AND m.period @> now() AND m.in_service AND e.in_service
      AND e.collector_id = collector_id AND NOT e.polled_by_other_system);
  IF strays IS NOT NULL THEN
    RAISE SQLSTATE '22023' USING
      MESSAGE = format('meters not polled by collector %s now: %s', collector_id, strays);
  END IF;

  INSERT INTO jobs.requests (collector_id, kind, requester, expires_at)
  VALUES (collector_id, 'read_on_demand', requester, now() + interval '1 hour')
  RETURNING request_id INTO id;
  INSERT INTO jobs.request_meters (request_id, serial) SELECT id, s FROM unnest(meters) s;
  RETURN id;
END
$_$;

GRANT ALL ON FUNCTION jobs.request_job(collector_id text, kind text, meters text[], requester text) TO minkanakku_staff;

-- Each table listed refuses UPDATE, DELETE and TRUNCATE (jobs.refuse_change).
DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'requests',
    'request_meters',
    'request_readings',
    'request_missed_reads',
    'request_fills',
    'request_fill_stores',
    'request_stored_entries',
    'request_fill_results'
  ] LOOP
    EXECUTE format(
      'CREATE TRIGGER refuse_change BEFORE UPDATE OR DELETE ON jobs.%I
         FOR EACH ROW EXECUTE FUNCTION jobs.refuse_change()', t);
    EXECUTE format(
      'CREATE TRIGGER refuse_truncate BEFORE TRUNCATE ON jobs.%I
         FOR EACH STATEMENT EXECUTE FUNCTION jobs.refuse_change()', t);
  END LOOP;
END
$$;

-- Each request as of now(): answered once what it asked for has come
-- (whenever that is, so a late answer still counts); else expired once
-- expires_at has passed; else pending. A read on demand is answered once any
-- reading or missed read came for it; a fill, once every meter and store it
-- named has a result. answered_at is when that was.
-- contract: central/test/requests.sql, central/test/fills.sql
CREATE VIEW jobs.request_status AS
  SELECT q.request_id, q.collector_id, q.kind, m.meters, q.requester, q.requested_at,
         q.expires_at, r.readings, x.missed_reads,
         CASE
           WHEN q.kind::text = 'fill_copies' THEN f.answered_at
           ELSE least(r.first_linked_at, x.first_linked_at)
         END AS answered_at,
         CASE
           WHEN q.kind::text = 'fill_copies' AND f.answered_at IS NOT NULL THEN 'answered'
           WHEN q.kind::text <> 'fill_copies' AND (r.readings > 0 OR x.missed_reads > 0)
             THEN 'answered'
           WHEN now() >= q.expires_at THEN 'expired'
           ELSE 'pending'
         END::jobs.state AS state,
         e.stored_entries, f.results AS fill_results
  FROM jobs.requests q
  CROSS JOIN LATERAL (
    SELECT array_agg(rm.serial ORDER BY rm.serial) AS meters, count(*) AS n
    FROM jobs.request_meters rm WHERE rm.request_id = q.request_id
  ) m
  CROSS JOIN LATERAL (
    SELECT count(*) AS readings, min(l.linked_at) AS first_linked_at
    FROM jobs.request_readings l WHERE l.request_id = q.request_id
  ) r
  CROSS JOIN LATERAL (
    SELECT count(*) AS missed_reads, min(l.linked_at) AS first_linked_at
    FROM jobs.request_missed_reads l WHERE l.request_id = q.request_id
  ) x
  CROSS JOIN LATERAL (
    SELECT count(*) AS stored_entries
    FROM jobs.request_stored_entries l WHERE l.request_id = q.request_id
  ) e
  CROSS JOIN LATERAL (
    SELECT count(*) AS n FROM jobs.request_fill_stores s WHERE s.request_id = q.request_id
  ) s
  -- A fill is answered when its last result came.
  CROSS JOIN LATERAL (
    SELECT count(*) AS results,
           CASE WHEN s.n > 0 AND count(*) = m.n * s.n THEN max(l.linked_at) END AS answered_at
    FROM jobs.request_fill_results l WHERE l.request_id = q.request_id
  ) f;

GRANT SELECT ON TABLE jobs.request_status TO minkanakku_staff;


-- ==== admin =================================================================

-- Change an endpoint from valid_from, stating its whole state: copy and
-- retry_ms have no default, so leaving one out cannot change it unseen.
-- contract: central/test/registry.sql
CREATE FUNCTION admin.change_endpoint(endpoint_id text, valid_from timestamp with time zone, collector_id text, host text, port integer, framing registry.framing, polled_by_other_system boolean, timeout_ms integer, max_timeouts integer, retries integer, busy_backoff_ms integer, reconnect_backoff_min_ms integer, reconnect_backoff_max_ms integer, interval_ms integer, retry_ms integer, copy boolean) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
#variable_conflict use_variable
DECLARE
  v bigint;
BEGIN
  IF NOT EXISTS (SELECT FROM registry.endpoints e WHERE e.id = endpoint_id) THEN
    RAISE EXCEPTION 'endpoint % is not registered', endpoint_id
      USING HINT = 'Register it with admin.register_endpoint.';
  END IF;
  INSERT INTO registry.endpoint_versions
    (endpoint_id, valid_from, in_service, collector_id, host, port, framing,
     polled_by_other_system, timeout_ms, max_timeouts, retries, busy_backoff_ms,
     reconnect_backoff_min_ms, reconnect_backoff_max_ms, interval_ms, retry_ms, copy)
  VALUES
    (endpoint_id, valid_from, true, collector_id, host, port, framing,
     polled_by_other_system, timeout_ms, max_timeouts, retries, busy_backoff_ms,
     reconnect_backoff_min_ms, reconnect_backoff_max_ms, interval_ms, retry_ms, copy)
  RETURNING version_id INTO v;
  PERFORM registry.check_history();
  RETURN v;
END
$$;

COMMENT ON FUNCTION admin.change_endpoint(endpoint_id text, valid_from timestamp with time zone, collector_id text, host text, port integer, framing registry.framing, polled_by_other_system boolean, timeout_ms integer, max_timeouts integer, retries integer, busy_backoff_ms integer, reconnect_backoff_min_ms integer, reconnect_backoff_max_ms integer, interval_ms integer, retry_ms integer, copy boolean) IS 'An endpoint''s whole state from valid_from: readdress it, move it to another collector, change how it is polled, switch copying on or off, or correct an earlier row. interval_ms divides a day.';

-- contract: central/test/registry.sql
CREATE FUNCTION admin.change_meter(serial text, valid_from timestamp with time zone, endpoint_id text, unit_id integer) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
#variable_conflict use_variable
DECLARE
  v bigint;
BEGIN
  IF NOT EXISTS (SELECT FROM registry.meters m WHERE m.serial = serial) THEN
    RAISE EXCEPTION 'meter % is not registered', serial
      USING HINT = 'Register it with admin.register_meter.';
  END IF;
  IF NOT EXISTS (SELECT FROM registry.targets g
                 WHERE (g.endpoint_id, g.unit_id) = (endpoint_id, unit_id)) THEN
    RAISE EXCEPTION '% unit % is not registered', endpoint_id, unit_id
      USING HINT = 'Register it with admin.register_target.';
  END IF;
  INSERT INTO registry.meter_versions (serial, valid_from, in_service, endpoint_id, unit_id)
  VALUES (serial, valid_from, true, endpoint_id, unit_id)
  RETURNING version_id INTO v;
  PERFORM registry.check_history();
  RETURN v;
END
$$;

COMMENT ON FUNCTION admin.change_meter(serial text, valid_from timestamp with time zone, endpoint_id text, unit_id integer) IS 'A meter''s whole state from valid_from: place it at another target, or correct an earlier row.';

-- Change a target from valid_from. retry_ms is required, NULL for the
-- endpoint's, as interval_ms is.
-- contract: central/test/registry.sql
CREATE FUNCTION admin.change_target(endpoint_id text, unit_id integer, valid_from timestamp with time zone, profile text, interval_ms integer, retry_ms integer) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
#variable_conflict use_variable
DECLARE
  v bigint;
BEGIN
  IF NOT EXISTS (SELECT FROM registry.targets g
                 WHERE (g.endpoint_id, g.unit_id) = (endpoint_id, unit_id)) THEN
    RAISE EXCEPTION '% unit % is not registered', endpoint_id, unit_id
      USING HINT = 'Register it with admin.register_target.';
  END IF;
  INSERT INTO registry.target_versions
    (endpoint_id, unit_id, valid_from, in_service, profile, interval_ms, retry_ms)
  VALUES (endpoint_id, unit_id, valid_from, true, profile, interval_ms, retry_ms)
  RETURNING version_id INTO v;
  PERFORM registry.check_history();
  RETURN v;
END
$$;

COMMENT ON FUNCTION admin.change_target(endpoint_id text, unit_id integer, valid_from timestamp with time zone, profile text, interval_ms integer, retry_ms integer) IS 'A target''s whole state from valid_from: its profile, its interval and its retry interval (NULL: its endpoint''s), or a correction of an earlier row. interval_ms divides a day.';

-- Holes in what the store holds of each copied meter's stores, for the
-- operator to judge: per target copied now whose meter is known
-- (health.copy_targets) and per store its profile copies, each slot (a day; a
-- month for history, by the meter's clock) from since, or from the store's
-- oldest entry of the serial if later, up to its newest, that holds no entry.
-- A store with no entry of the serial has no holes: it is behind
-- (health.copy_stores). gone: a fill result showed the meter no longer held
-- the slot. pending_request: the newest fill offered now that covers the slot
-- and has no result for it yet. Entries are looked up by serial, store and
-- stamp range, within the slot's chunk.
--   SELECT * FROM admin.copy_holes(since => '2026-10-01');
-- contract: central/test/fills.sql
CREATE FUNCTION admin.copy_holes(since timestamp without time zone) RETURNS TABLE(serial text, store store.stored_store, slot_start timestamp without time zone, slot_end timestamp without time zone, profile text, collector_id text, endpoint_id text, unit_id smallint, host text, port integer, gone boolean, pending_request uuid)
    LANGUAGE sql STABLE
    AS $$
  WITH w AS (
    SELECT k.serial, s.store, k.profile, k.collector_id, k.endpoint_id, k.unit_id, k.host,
           k.port,
           CASE WHEN s.store = 'history' THEN 'month' ELSE 'day' END AS unit,
           CASE WHEN s.store = 'history' THEN interval '1 month' ELSE interval '1 day' END AS step
    FROM health.copy_targets k
    CROSS JOIN LATERAL (SELECT DISTINCT p.store FROM store.profile_stored p
                        WHERE p.profile = k.profile) s
    WHERE k.serial IS NOT NULL
  ), b AS (
    SELECT w.*, x.oldest, x.newest
    FROM w
    CROSS JOIN LATERAL (
      SELECT min(o.meter_time) AS oldest, max(n.meter_time) AS newest
      FROM (SELECT DISTINCT p.register_key FROM store.profile_stored p
            WHERE p.profile = w.profile AND p.store = w.store) r
      CROSS JOIN LATERAL (
        SELECT e.meter_time FROM store.stored_entries e
        WHERE (e.meter_serial, e.store, e.register_key) = (w.serial, w.store, r.register_key)
        ORDER BY e.meter_time LIMIT 1) o
      CROSS JOIN LATERAL (
        SELECT e.meter_time FROM store.stored_entries e
        WHERE (e.meter_serial, e.store, e.register_key) = (w.serial, w.store, r.register_key)
        ORDER BY e.meter_time DESC LIMIT 1) n
    ) x
    WHERE x.newest IS NOT NULL
  )
  SELECT b.serial, b.store, d, d + b.step, b.profile, b.collector_id, b.endpoint_id, b.unit_id,
         b.host, b.port,
         EXISTS (
           SELECT FROM jobs.request_fill_results r
           JOIN jobs.request_fills f ON f.request_id = r.request_id
           WHERE (r.meter_serial, r.store) = (b.serial, b.store)
             AND d < r.gone_before AND d + b.step > f.from_time),
         (SELECT f.request_id
          FROM jobs.request_fills f
          JOIN jobs.requests q ON q.request_id = f.request_id
          JOIN jobs.request_meters m ON (m.request_id, m.serial) = (f.request_id, b.serial)
          JOIN jobs.request_fill_stores s ON (s.request_id, s.store) = (f.request_id, b.store)
          WHERE q.expires_at > now() AND d < f.to_time AND d + b.step > f.from_time
            AND NOT EXISTS (SELECT FROM jobs.request_fill_results r
                            WHERE (r.request_id, r.meter_serial, r.store)
                                  = (f.request_id, b.serial, b.store))
          ORDER BY q.requested_at DESC, f.request_id
          LIMIT 1)
  FROM b
  CROSS JOIN LATERAL generate_series(date_trunc(b.unit, greatest(since, b.oldest)),
                                     date_trunc(b.unit, b.newest), b.step) d
  -- LIMIT keeps this a lookup per slot, as in health.missed_snapshots.
  LEFT JOIN LATERAL (
    SELECT true AS held FROM store.stored_entries e
    WHERE e.meter_serial = b.serial AND e.store = b.store
      AND e.meter_time >= d AND e.meter_time < d + b.step
    LIMIT 1
  ) e ON true
  WHERE e.held IS NULL
  ORDER BY b.serial, b.store, d
$$;

-- Register a collector: its row and a role of its own, which the collector's
-- token names (central/bin/collector-token).
-- contract: central/test/grants.sql
CREATE FUNCTION admin.create_collector(collector_id text) RETURNS name
    LANGUAGE plpgsql
    AS $$
DECLARE
  r name;
BEGIN
  INSERT INTO store.collectors (id) VALUES (collector_id) RETURNING role INTO r;
  EXECUTE format('CREATE ROLE %I NOLOGIN', r);
  EXECUTE format('GRANT collector TO %I WITH INHERIT TRUE, SET FALSE', r);
  EXECUTE format('GRANT %I TO authenticator WITH INHERIT FALSE, SET TRUE', r);
  RETURN r;
END
$$;

-- Load one contract/latency file's version, as the owner. A version already
-- loaded is left as it is when the file gives the same bounds, and refused
-- (22023) otherwise. Returns 'new' or 'already loaded'. Run by
-- bin/load-profiles.
-- contract: central/test/latency.sql
CREATE FUNCTION admin.load_latency_buckets(document jsonb) RETURNS text
    LANGUAGE plpgsql
    AS $$
DECLARE
  v bigint;
  bounds integer[];
  loaded integer[];
BEGIN
  IF jsonb_typeof(document -> 'version') IS DISTINCT FROM 'number'
     OR (document -> 'version')::numeric <> trunc((document -> 'version')::numeric)
     OR (document -> 'version')::numeric < 1 THEN
    RAISE SQLSTATE '22023' USING MESSAGE = 'latency buckets: version must be a positive integer';
  END IF;
  v := (document -> 'version')::numeric;
  IF jsonb_typeof(document -> 'bounds_ms') IS DISTINCT FROM 'array'
     OR jsonb_array_length(document -> 'bounds_ms') = 0
     OR EXISTS (
       SELECT FROM jsonb_array_elements(document -> 'bounds_ms') WITH ORDINALITY b(x, i)
       WHERE jsonb_typeof(b.x) IS DISTINCT FROM 'number'
          OR b.x::numeric <> trunc(b.x::numeric) OR b.x::numeric < 1
          OR b.x::numeric > 2147483647
          OR b.x::numeric <= (document -> 'bounds_ms' -> (b.i::integer - 2))::numeric
             AND b.i > 1) THEN
    RAISE SQLSTATE '22023' USING MESSAGE = format(
      'latency buckets version %s: bounds_ms must be a non-empty list of increasing positive integers', v);
  END IF;
  bounds := ARRAY(SELECT x::numeric::integer
                  FROM jsonb_array_elements(document -> 'bounds_ms') WITH ORDINALITY b(x, i)
                  ORDER BY i);

  SELECT bounds_ms INTO loaded FROM store.latency_bucket_versions WHERE version = v;
  IF NOT FOUND THEN
    INSERT INTO store.latency_bucket_versions (version, bounds_ms) VALUES (v, bounds);
    RETURN 'new';
  END IF;
  IF loaded IS DISTINCT FROM bounds THEN
    RAISE SQLSTATE '22023' USING MESSAGE = format(
      'latency buckets version %s is loaded with other bounds; a change is a new version', v);
  END IF;
  RETURN 'already loaded';
END
$$;

-- Load one profile file's version into the catalog, as the owner: its
-- registers, and its stored quantities where it has a stored section. A
-- version already loaded is left as it is when the file names the same
-- registers and stored quantities with the same decode, table, address or
-- parameter, unit and kind, and refused (22023) otherwise. A stored section
-- must list a quantity in each store it names. Returns 'new' or 'already
-- loaded'. Run by bin/load-profiles.
-- contract: central/test/profiles.sql
CREATE FUNCTION admin.load_profile(document jsonb) RETURNS text
    LANGUAGE plpgsql
    AS $$
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

-- Register an endpoint and its first version. A new endpoint copies nothing
-- unless copy says so.
-- contract: central/test/registry.sql
CREATE FUNCTION admin.register_endpoint(endpoint_id text, valid_from timestamp with time zone, collector_id text, host text, port integer, framing registry.framing, polled_by_other_system boolean, timeout_ms integer, max_timeouts integer, retries integer, busy_backoff_ms integer, reconnect_backoff_min_ms integer, reconnect_backoff_max_ms integer, interval_ms integer, retry_ms integer, copy boolean DEFAULT false) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
BEGIN
  INSERT INTO registry.endpoints (id) VALUES (endpoint_id);
  RETURN admin.change_endpoint(
    endpoint_id, valid_from, collector_id, host, port, framing, polled_by_other_system,
    timeout_ms, max_timeouts, retries, busy_backoff_ms, reconnect_backoff_min_ms,
    reconnect_backoff_max_ms, interval_ms, retry_ms, copy);
END
$$;

-- Register a meter by serial and place it at a target from valid_from.
-- contract: central/test/registry.sql
CREATE FUNCTION admin.register_meter(serial text, valid_from timestamp with time zone, endpoint_id text, unit_id integer) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
BEGIN
  INSERT INTO registry.meters (serial) VALUES (serial);
  RETURN admin.change_meter(serial, valid_from, endpoint_id, unit_id);
END
$$;

-- Register a target and its first version.
-- contract: central/test/registry.sql
CREATE FUNCTION admin.register_target(endpoint_id text, unit_id integer, valid_from timestamp with time zone, profile text, interval_ms integer, retry_ms integer) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
BEGIN
  INSERT INTO registry.targets (endpoint_id, unit_id) VALUES (endpoint_id, unit_id);
  RETURN admin.change_target(endpoint_id, unit_id, valid_from, profile, interval_ms, retry_ms);
END
$$;

-- Ask a collector to copy what its meters hold of these stores between two
-- meter-clock times, as the operator. Each meter must be in service now on
-- an endpoint in service now with that collector, copying, and polled by no
-- other system. Refused with 22023 otherwise. expires_after is how long the request is offered.
--   SELECT admin.request_fill(collector_id => 'pilot_01', meters => ARRAY['…'],
--     stores => ARRAY['load_survey'], from_time => '2026-10-01', to_time => '2026-11-01',
--     requester => 'operator', expires_after => '3 days');
-- contract: central/test/fills.sql
CREATE FUNCTION admin.request_fill(collector_id text, meters text[], stores text[], from_time timestamp without time zone, to_time timestamp without time zone, requester text, expires_after interval) RETURNS uuid
    LANGUAGE plpgsql
    AS $_$
#variable_conflict use_variable
DECLARE
  id uuid;
  strays text;
BEGIN
  IF NOT EXISTS (SELECT FROM store.collectors c WHERE c.id = collector_id) THEN
    RAISE SQLSTATE '22023' USING
      MESSAGE = format('collector %s is not registered', collector_id);
  END IF;
  IF requester IS NULL OR requester !~ '^[^[:cntrl:]]{1,200}$' THEN
    RAISE SQLSTATE '22023' USING
      MESSAGE = 'requester must be 1 to 200 characters with no control characters';
  END IF;
  IF coalesce(cardinality(meters), 0) = 0 OR array_position(meters, NULL) IS NOT NULL
     OR cardinality(meters) <> (SELECT count(DISTINCT s) FROM unnest(meters) s) THEN
    RAISE SQLSTATE '22023' USING
      MESSAGE = 'meters must name at least one serial, each once, and no NULL';
  END IF;
  IF coalesce(cardinality(stores), 0) = 0 OR array_position(stores, NULL) IS NOT NULL
     OR cardinality(stores) <> (SELECT count(DISTINCT s) FROM unnest(stores) s)
     OR NOT stores <@ enum_range(NULL::store.stored_store)::text[] THEN
    RAISE SQLSTATE '22023' USING
      MESSAGE = format('stores must name at least one of %s, each once',
        array_to_string(enum_range(NULL::store.stored_store), ', '));
  END IF;
  IF from_time IS NULL OR to_time IS NULL OR from_time >= to_time
     OR date_trunc('second', from_time) <> from_time OR date_trunc('second', to_time) <> to_time THEN
    RAISE SQLSTATE '22023' USING
      MESSAGE = 'from_time must be before to_time, both whole seconds of the meters'' clock';
  END IF;
  IF expires_after IS NULL OR expires_after <= interval '0' THEN
    RAISE SQLSTATE '22023' USING MESSAGE = 'expires_after must be a positive interval';
  END IF;

  SELECT string_agg(s, ', ' ORDER BY s) INTO strays
  FROM unnest(meters) s
  WHERE NOT EXISTS (
    SELECT FROM registry.meter_history m
    JOIN registry.endpoint_history e ON e.endpoint_id = m.endpoint_id AND e.period @> now()
    JOIN registry.target_history g
      ON (g.endpoint_id, g.unit_id) = (m.endpoint_id, m.unit_id) AND g.period @> now()
    WHERE m.serial = s AND m.period @> now() AND m.in_service AND e.in_service AND g.in_service
      AND e.collector_id = collector_id AND e.copy AND NOT e.polled_by_other_system);
  IF strays IS NOT NULL THEN
    RAISE SQLSTATE '22023' USING
      MESSAGE = format('meters not copied by collector %s now: %s', collector_id, strays);
  END IF;

  INSERT INTO jobs.requests (collector_id, kind, requester, expires_at)
  VALUES (collector_id, 'fill_copies', requester, now() + expires_after)
  RETURNING request_id INTO id;
  INSERT INTO jobs.request_meters (request_id, serial) SELECT id, s FROM unnest(meters) s;
  INSERT INTO jobs.request_fills (request_id, from_time, to_time) VALUES (id, from_time, to_time);
  INSERT INTO jobs.request_fill_stores (request_id, store)
  SELECT id, s::store.stored_store FROM unnest(stores) s;
  RETURN id;
END
$_$;

-- Take an endpoint out of service from valid_from; its other settings stay
-- as they were last.
-- contract: central/test/registry.sql
CREATE FUNCTION admin.retire_endpoint(endpoint_id text, valid_from timestamp with time zone) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
#variable_conflict use_variable
DECLARE
  v bigint;
BEGIN
  INSERT INTO registry.endpoint_versions
    (endpoint_id, valid_from, in_service, collector_id, host, port, framing,
     polled_by_other_system, timeout_ms, max_timeouts, retries, busy_backoff_ms,
     reconnect_backoff_min_ms, reconnect_backoff_max_ms, interval_ms, retry_ms, copy)
  SELECT h.endpoint_id, valid_from, false, h.collector_id, h.host, h.port, h.framing,
         h.polled_by_other_system, h.timeout_ms, h.max_timeouts, h.retries, h.busy_backoff_ms,
         h.reconnect_backoff_min_ms, h.reconnect_backoff_max_ms, h.interval_ms, h.retry_ms,
         h.copy
    FROM registry.endpoint_history h
   WHERE h.endpoint_id = endpoint_id AND h.period @> valid_from AND h.in_service
  RETURNING version_id INTO v;
  IF v IS NULL THEN
    RAISE EXCEPTION 'endpoint % is not in service at %', endpoint_id, valid_from;
  END IF;
  PERFORM registry.check_history();
  RETURN v;
END
$$;

-- Take a meter out of service from valid_from, at the target it was at.
-- contract: central/test/registry.sql
CREATE FUNCTION admin.retire_meter(serial text, valid_from timestamp with time zone) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
#variable_conflict use_variable
DECLARE
  v bigint;
BEGIN
  INSERT INTO registry.meter_versions (serial, valid_from, in_service, endpoint_id, unit_id)
  SELECT h.serial, valid_from, false, h.endpoint_id, h.unit_id
    FROM registry.meter_history h
   WHERE h.serial = serial AND h.period @> valid_from AND h.in_service
  RETURNING version_id INTO v;
  IF v IS NULL THEN
    RAISE EXCEPTION 'meter % is not in service at %', serial, valid_from;
  END IF;
  PERFORM registry.check_history();
  RETURN v;
END
$$;

-- Take a target out of service from valid_from, keeping how it was polled.
-- contract: central/test/registry.sql
CREATE FUNCTION admin.retire_target(endpoint_id text, unit_id integer, valid_from timestamp with time zone) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
#variable_conflict use_variable
DECLARE
  v bigint;
BEGIN
  INSERT INTO registry.target_versions
    (endpoint_id, unit_id, valid_from, in_service, profile, interval_ms, retry_ms)
  SELECT h.endpoint_id, h.unit_id, valid_from, false, h.profile, h.interval_ms, h.retry_ms
    FROM registry.target_history h
   WHERE (h.endpoint_id, h.unit_id) = (endpoint_id, unit_id) AND h.period @> valid_from
     AND h.in_service
  RETURNING version_id INTO v;
  IF v IS NULL THEN
    RAISE EXCEPTION '% unit % is not in service at %', endpoint_id, unit_id, valid_from;
  END IF;
  PERFORM registry.check_history();
  RETURN v;
END
$$;

-- contract: central/test/collector_config.sql
CREATE FUNCTION admin.set_copy_window(collector_id text, valid_from timestamp with time zone, start_time time without time zone, end_time time without time zone) RETURNS bigint
    LANGUAGE sql
    AS $$
  INSERT INTO registry.copy_window_versions (collector_id, valid_from, start_time, end_time)
  VALUES (collector_id, valid_from, start_time, end_time)
  RETURNING version_id
$$;

COMMENT ON FUNCTION admin.set_copy_window(collector_id text, valid_from timestamp with time zone, start_time time without time zone, end_time time without time zone) IS 'A collector''s copy window from valid_from, in its local wall-clock time; a collector with none in force is served a config without one, which it refuses.';

-- Set every health threshold at once, as a new row; the newest row holds
-- (health.thresholds). Returns its version_id.
-- contract: central/test/health.sql
CREATE FUNCTION admin.set_health_thresholds(collector_silent_after interval, meter_silent_intervals numeric, backlog_near_capacity numeric, lookback interval, endpoint_error_rate numeric, snapshot_missed_margin interval, history_behind_after interval, snapshot_behind_after_elite_500 interval, load_survey_behind_after_elite_440 interval, load_survey_behind_after_elite_500 interval, meter_clock_step_after interval, meter_clock_far_after interval, copy_failing_interval interval) RETURNS bigint
    LANGUAGE sql
    AS $$
  INSERT INTO registry.health_thresholds
    (collector_silent_after, meter_silent_intervals, backlog_near_capacity, lookback,
     endpoint_error_rate, snapshot_missed_margin, history_behind_after,
     snapshot_behind_after_elite_500, load_survey_behind_after_elite_440,
     load_survey_behind_after_elite_500, meter_clock_step_after, meter_clock_far_after,
     copy_failing_interval)
  VALUES (collector_silent_after, meter_silent_intervals, backlog_near_capacity, lookback,
          endpoint_error_rate, snapshot_missed_margin, history_behind_after,
          snapshot_behind_after_elite_500, load_survey_behind_after_elite_440,
          load_survey_behind_after_elite_500, meter_clock_step_after, meter_clock_far_after,
          copy_failing_interval)
  RETURNING version_id
$$;

-- The new meter may already be registered (a spare that was in service
-- elsewhere). It takes the old one's target, which keeps its profile: a new
-- meter of another model needs admin.change_target from the same time.
CREATE FUNCTION admin.swap_meter(old_serial text, new_serial text, swapped_at timestamp with time zone) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
#variable_conflict use_variable
DECLARE
  was registry.meter_history;
BEGIN
  SELECT * INTO was FROM registry.meter_history h
   WHERE h.serial = old_serial AND h.period @> swapped_at AND h.in_service;
  IF was.serial IS NULL THEN
    RAISE EXCEPTION 'meter % is not in service at %', old_serial, swapped_at;
  END IF;
  PERFORM admin.retire_meter(old_serial, swapped_at);
  INSERT INTO registry.meters (serial) VALUES (new_serial) ON CONFLICT DO NOTHING;
  INSERT INTO registry.meter_swaps (old_serial, new_serial, swapped_at)
  VALUES (old_serial, new_serial, swapped_at);
  RETURN admin.change_meter(new_serial, swapped_at, was.endpoint_id, was.unit_id);
END
$$;


-- ==== api ===================================================================

-- GET /rpc/collector_config: the calling collector's polling config, or 403
-- for a role that is not a registered collector.
-- contract: central/test/collector_config.sql, central/test/grants.sql
CREATE FUNCTION api.collector_config() RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
DECLARE
  caller text := store.caller();
BEGIN
  IF caller IS NULL THEN
    RAISE SQLSTATE 'PT403' USING MESSAGE = 'the caller is not a registered collector';
  END IF;
  RETURN registry.collector_config(caller);
END
$$;

GRANT ALL ON FUNCTION api.collector_config() TO collector;

-- Store a batch: POST /rpc/ingest with the batch as the JSON body, as one
-- transaction. Answers 200, 422 (schema; a register, stored quantity or
-- latency bucket its version does not fit), 503 (a profile or bucket version
-- not loaded, so the collector keeps the batch), 409 (batch id of another
-- collector) or 403 (not a collector). Idempotent: every event is keyed, a
-- resent one is counted duplicate, and one that differs under a taken key is
-- kept as a conflict, a latency entry's late counts included. Links what came
-- for the caller's requests (jobs.link_batch, jobs.link_fills). Keeps the
-- backlog and config the collector reported with the upload, and answers with
-- the digest of the config it is served now and its pending jobs. A batch
-- with no events is a heartbeat.
-- contract: central/test/ingest.sql, central/test/stored.sql, central/test/requests.sql,
--   central/test/collector_config.sql, central/test/fills.sql, central/test/latency.sql
CREATE FUNCTION api.ingest(jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $_$
DECLARE
  b jsonb := $1;
  caller text := store.caller();
  id uuid;
  owner text;
  first_received timestamptz;
  resent boolean;
  readings_in integer;
  readings_new integer;
  readings_conflicting integer;
  missed_in integer;
  missed_new integer;
  firmware_in integer;
  firmware_new integer;
  firmware_conflicting integer;
  checks_in integer;
  checks_new integer;
  checks_conflicting integer;
  latency_in integer;
  latency_new integer;
  latency_conflicting integer;
  entries_in integer;
  entries_new integer;
  entries_conflicting integer;
  meter_clocks_in integer;
  meter_clocks_new integer;
  meter_clocks_conflicting integer;
  unknown_requests uuid[];
  fills jsonb;
BEGIN
  IF caller IS NULL THEN
    RAISE SQLSTATE 'PT403' USING MESSAGE = 'the caller is not a registered collector';
  END IF;
  PERFORM store.check_batch(b);
  PERFORM store.check_catalog(b);
  PERFORM store.check_copied_catalog(b);
  PERFORM store.check_latency(b);
  id := (b ->> 'batch_id')::uuid;
  readings_in := jsonb_array_length(b -> 'readings');
  missed_in := jsonb_array_length(b -> 'missed_reads');
  firmware_in := coalesce(jsonb_array_length(b -> 'firmware_reads'), 0);
  checks_in := coalesce(jsonb_array_length(b -> 'clock_checks'), 0);
  latency_in := coalesce(jsonb_array_length(b -> 'latency'), 0);
  entries_in := coalesce(jsonb_array_length(b -> 'stored_entries'), 0);
  meter_clocks_in := coalesce(jsonb_array_length(b -> 'meter_clock_reads'), 0);

  INSERT INTO store.batches
    (batch_id, collector_id, received_at, clock_source, clock_last_sync_at, readings, missed_reads)
  VALUES
    (id, caller, now(), (b -> 'clock' ->> 'source')::store.clock_source,
     (b -> 'clock' ->> 'last_sync_at')::timestamptz, readings_in, missed_in)
  ON CONFLICT (batch_id) DO NOTHING;
  resent := NOT FOUND;

  SELECT collector_id, received_at INTO owner, first_received
    FROM store.batches WHERE batch_id = id;
  IF owner <> caller THEN
    RAISE SQLSTATE 'PT409' USING MESSAGE = format('batch %s was sent by another collector', id);
  END IF;

  WITH inserted AS (
    INSERT INTO store.readings
      (meter_serial, register_key, read_at, value, profile, profile_version, endpoint_host,
       endpoint_port, unit_id, product_code, collector_id, batch_id)
    SELECT r.*, caller, id FROM store.batch_readings(b) r
    ON CONFLICT (meter_serial, register_key, read_at) DO NOTHING
    RETURNING 1
  )
  SELECT count(*) INTO readings_new FROM inserted;

  WITH differing AS (
    SELECT r.*
    FROM store.batch_readings(b) r
    JOIN store.readings s USING (meter_serial, register_key, read_at)
    WHERE (s.value::text, s.profile, s.profile_version, s.endpoint_host, s.endpoint_port,
           s.unit_id, s.product_code)
          IS DISTINCT FROM
          (r.value::text, r.profile, r.profile_version, r.endpoint_host, r.endpoint_port,
           r.unit_id, r.product_code)
  ), kept AS (
    INSERT INTO store.reading_conflicts
      (meter_serial, register_key, read_at, value, profile, profile_version, endpoint_host,
       endpoint_port, unit_id, product_code, collector_id, batch_id, received_at)
    SELECT d.*, caller, id, now() FROM differing d
    ON CONFLICT DO NOTHING
  )
  SELECT count(*) INTO readings_conflicting FROM differing;

  WITH inserted AS (
    INSERT INTO store.missed_reads
      (meter_serial, register_key, read_at, reason, exception_code, detail, attempts, raw_words,
       profile, profile_version, endpoint_host, endpoint_port, unit_id, collector_id, batch_id)
    SELECT m.*, caller, id FROM store.batch_missed_reads(b) m
    ON CONFLICT (collector_id, endpoint_host, endpoint_port, unit_id, register_key, read_at)
      DO NOTHING
    RETURNING 1
  )
  SELECT count(*) INTO missed_new FROM inserted;

  WITH inserted AS (
    INSERT INTO store.firmware_reads
      (meter_serial, product_code, read_at, software, firmware_1, firmware_2, modbus_version,
       endpoint_host, endpoint_port, unit_id, collector_id, batch_id)
    SELECT f.*, caller, id FROM store.batch_firmware_reads(b) f
    ON CONFLICT (collector_id, endpoint_host, endpoint_port, unit_id, read_at) DO NOTHING
    RETURNING 1
  )
  SELECT count(*) INTO firmware_new FROM inserted;

  -- Counted, not kept: names are not charged on, and the stored record stands.
  SELECT count(*) INTO firmware_conflicting
  FROM store.batch_firmware_reads(b) f
  JOIN store.firmware_reads s USING (endpoint_host, endpoint_port, unit_id, read_at)
  WHERE s.collector_id = caller
    AND (s.meter_serial, s.product_code, s.software, s.firmware_1, s.firmware_2, s.modbus_version)
        IS DISTINCT FROM
        (f.meter_serial, f.product_code, f.software, f.firmware_1, f.firmware_2, f.modbus_version);

  WITH inserted AS (
    INSERT INTO store.clock_checks
      (t1, t4, trigger, server, outcome, t2_unix, t3_unix, address, stratum, leap, reference_id,
       collector_id, batch_id)
    SELECT c.*, caller, id FROM store.batch_clock_checks(b) c
    ON CONFLICT (collector_id, t1) DO NOTHING
    RETURNING 1
  )
  SELECT count(*) INTO checks_new FROM inserted;

  -- Counted, not kept, as firmware reads: the stored check stands.
  SELECT count(*) INTO checks_conflicting
  FROM store.batch_clock_checks(b) c
  JOIN store.clock_checks s ON s.collector_id = caller AND s.t1 = c.t1
  WHERE (s.t4, s.trigger, s.server, s.outcome, s.t2_unix, s.t3_unix, s.address, s.stratum,
         s.leap, s.reference_id)
        IS DISTINCT FROM
        (c.t4, c.trigger, c.server, c.outcome, c.t2_unix, c.t3_unix, c.address, c.stratum,
         c.leap, c.reference_id);

  WITH inserted AS (
    INSERT INTO store.latency_days
      (endpoint_host, endpoint_port, unit_id, day, poller_started_at, buckets_version, retries,
       timeouts, max_ms, buckets, late_data, late_exceptions, collector_id, batch_id)
    SELECT l.*, caller, id FROM store.batch_latency_days(b) l
    ON CONFLICT (collector_id, endpoint_host, endpoint_port, unit_id, day, poller_started_at)
      DO NOTHING
    RETURNING 1
  )
  SELECT count(*) INTO latency_new FROM inserted;

  -- Counted, not kept, as clock checks: the stored entry stands.
  SELECT count(*) INTO latency_conflicting
  FROM store.batch_latency_days(b) l
  JOIN store.latency_days s
    ON (s.collector_id, s.endpoint_host, s.endpoint_port, s.unit_id, s.day, s.poller_started_at)
       = (caller, l.endpoint_host, l.endpoint_port, l.unit_id, l.day, l.poller_started_at)
  WHERE (s.buckets_version, s.retries, s.timeouts, s.max_ms, s.buckets, s.late_data,
         s.late_exceptions)
        IS DISTINCT FROM
        (l.buckets_version, l.retries, l.timeouts, l.max_ms, l.buckets, l.late_data,
         l.late_exceptions);

  WITH inserted AS (
    INSERT INTO store.stored_entries
      (meter_serial, store, register_key, meter_time, value, interval_s, profile, profile_version,
       product_code, slot, copied_at, request_id, endpoint_host, endpoint_port, unit_id,
       collector_id, batch_id)
    SELECT e.*, caller, id FROM store.batch_stored_entries(b) e
    ON CONFLICT (meter_serial, store, register_key, meter_time) DO NOTHING
    RETURNING 1
  )
  SELECT count(*) INTO entries_new FROM inserted;

  WITH differing AS (
    SELECT e.*
    FROM store.batch_stored_entries(b) e
    JOIN store.stored_entries s USING (meter_serial, store, register_key, meter_time)
    WHERE (s.value::text, s.interval_s, s.profile, s.profile_version, s.product_code)
          IS DISTINCT FROM
          (e.value::text, e.interval_s, e.profile, e.profile_version, e.product_code)
  ), kept AS (
    INSERT INTO store.stored_entry_conflicts
      (meter_serial, store, register_key, meter_time, value, interval_s, profile, profile_version,
       product_code, slot, copied_at, request_id, endpoint_host, endpoint_port, unit_id,
       collector_id, batch_id, received_at)
    SELECT d.*, caller, id, now() FROM differing d
    ON CONFLICT DO NOTHING
  )
  SELECT count(*) INTO entries_conflicting FROM differing;

  WITH inserted AS (
    INSERT INTO store.meter_clock_reads
      (endpoint_host, endpoint_port, unit_id, collector_at, meter_serial, profile,
       profile_version, meter_time, collector_id, batch_id)
    SELECT m.*, caller, id FROM store.batch_meter_clock_reads(b) m
    ON CONFLICT (collector_id, endpoint_host, endpoint_port, unit_id, collector_at) DO NOTHING
    RETURNING 1
  )
  SELECT count(*) INTO meter_clocks_new FROM inserted;

  WITH differing AS (
    SELECT m.*
    FROM store.batch_meter_clock_reads(b) m
    JOIN store.meter_clock_reads s
      ON (s.collector_id, s.endpoint_host, s.endpoint_port, s.unit_id, s.collector_at)
         = (caller, m.endpoint_host, m.endpoint_port, m.unit_id, m.collector_at)
    WHERE (s.meter_serial, s.profile, s.profile_version, s.meter_time)
          IS DISTINCT FROM (m.meter_serial, m.profile, m.profile_version, m.meter_time)
  ), kept AS (
    INSERT INTO store.meter_clock_read_conflicts
      (endpoint_host, endpoint_port, unit_id, collector_at, meter_serial, profile,
       profile_version, meter_time, collector_id, batch_id, received_at)
    SELECT d.*, caller, id, now() FROM differing d
    ON CONFLICT DO NOTHING
  )
  SELECT count(*) INTO meter_clocks_conflicting FROM differing;

  unknown_requests := jobs.link_batch(b, caller, id);
  fills := jobs.link_fills(b, caller, id);

  INSERT INTO store.uploads
    (batch_id, collector_id, received_at, sent_at, backlog_events, backlog_bytes,
     backlog_batches, backlog_oldest, backlog_max_bytes, backlog_refused,
     backlog_discarded_files, backlog_quarantined, readings_inserted, readings_duplicate,
     readings_conflicting, missed_reads_inserted, missed_reads_duplicate, config_digest,
     config_refused_digest, config_refusal_reason, stored_entries_inserted,
     stored_entries_duplicate, stored_entries_conflicting, meter_clock_reads_inserted,
     meter_clock_reads_duplicate, meter_clock_reads_conflicting)
  SELECT id, caller, now(), (b ->> 'sent_at')::timestamptz,
         (k ->> 'events')::numeric, (k ->> 'bytes')::numeric, (k ->> 'batches')::numeric,
         (k ->> 'oldest')::timestamptz, (k ->> 'max_bytes')::numeric,
         (k ->> 'refused')::numeric, (k ->> 'discarded_files')::numeric,
         (k ->> 'quarantined')::numeric,
         readings_new, readings_in - readings_new - readings_conflicting, readings_conflicting,
         missed_new, missed_in - missed_new,
         k -> 'config' ->> 'digest', k -> 'config' ->> 'refused_digest',
         k -> 'config' ->> 'reason',
         entries_new, entries_in - entries_new - entries_conflicting, entries_conflicting,
         meter_clocks_new, meter_clocks_in - meter_clocks_new - meter_clocks_conflicting,
         meter_clocks_conflicting
  FROM (SELECT b -> 'backlog' AS k) backlog;

  -- jobs and unknown_requests are left out when there are none.
  RETURN jsonb_build_object(
    'batch_id', id,
    'resent', resent,
    'first_received_at', first_received,
    'config_digest', registry.config_digest(registry.collector_config(caller)),
    'readings', jsonb_build_object(
      'received', readings_in,
      'inserted', readings_new,
      'duplicate', readings_in - readings_new - readings_conflicting,
      'conflicting', readings_conflicting),
    'missed_reads', jsonb_build_object(
      'received', missed_in,
      'inserted', missed_new,
      'duplicate', missed_in - missed_new),
    'firmware_reads', jsonb_build_object(
      'received', firmware_in,
      'inserted', firmware_new,
      'duplicate', firmware_in - firmware_new - firmware_conflicting,
      'conflicting', firmware_conflicting),
    'clock_checks', jsonb_build_object(
      'received', checks_in,
      'inserted', checks_new,
      'duplicate', checks_in - checks_new - checks_conflicting,
      'conflicting', checks_conflicting),
    'latency', jsonb_build_object(
      'received', latency_in,
      'inserted', latency_new,
      'duplicate', latency_in - latency_new - latency_conflicting,
      'conflicting', latency_conflicting),
    'stored_entries', jsonb_build_object(
      'received', entries_in,
      'inserted', entries_new,
      'duplicate', entries_in - entries_new - entries_conflicting,
      'conflicting', entries_conflicting),
    'meter_clock_reads', jsonb_build_object(
      'received', meter_clocks_in,
      'inserted', meter_clocks_new,
      'duplicate', meter_clocks_in - meter_clocks_new - meter_clocks_conflicting,
      'conflicting', meter_clocks_conflicting),
    'fill_results', fills)
    || jsonb_strip_nulls(jsonb_build_object(
         'jobs', jobs.pending(caller),
         'unknown_requests', to_jsonb(unknown_requests)));
END
$_$;

GRANT ALL ON FUNCTION api.ingest(jsonb) TO collector;


-- ==== health ================================================================

-- The thresholds in force: the newest row of registry.health_thresholds.
-- contract: central/test/health.sql
CREATE VIEW health.thresholds AS
  SELECT collector_silent_after, meter_silent_intervals, backlog_near_capacity, lookback, set_at,
         endpoint_error_rate, snapshot_missed_margin, history_behind_after,
         snapshot_behind_after_elite_500, load_survey_behind_after_elite_440,
         load_survey_behind_after_elite_500, meter_clock_step_after, meter_clock_far_after,
         copy_failing_interval
  FROM registry.health_thresholds
  ORDER BY version_id DESC
  LIMIT 1;

GRANT SELECT ON TABLE health.thresholds TO monitor;

-- Per collector: in service while it has an endpoint in service; its last
-- upload and the backlog that upload reported; its last reading; its batch's
-- clock claim; missed reads within the lookback by reason. Silent: in
-- service, and no upload for collector_silent_after (counted from
-- registration when it has none). Near capacity: backlog at
-- backlog_near_capacity of its buffer.
-- contract: central/test/health.sql
CREATE VIEW health.collectors AS
  WITH t AS (SELECT collector_silent_after, meter_silent_intervals, backlog_near_capacity, lookback, set_at, endpoint_error_rate FROM health.thresholds),
  c AS (
    SELECT c.id AS collector_id, c.created_at,
           (SELECT count(*) FROM registry.endpoint_history e
            WHERE e.collector_id = c.id AND e.in_service AND e.period @> now()) AS endpoints
    FROM store.collectors c
  )
  SELECT c.collector_id, c.endpoints > 0 AS in_service, c.endpoints,
         u.received_at AS last_upload_at,
         (SELECT max(r.read_at) FROM store.readings r WHERE r.collector_id = c.collector_id)
           AS last_reading_at,
         b.clock_source, b.clock_last_sync_at,
         u.backlog_events, u.backlog_bytes, u.backlog_batches, u.backlog_oldest,
         u.backlog_max_bytes,
         round(u.backlog_bytes::numeric / u.backlog_max_bytes, 4) AS backlog_used,
         u.backlog_refused, u.backlog_discarded_files, u.backlog_quarantined,
         coalesce(m.missed, 0) AS missed_reads, coalesce(m.by_reason, '{}') AS missed_by_reason,
         c.endpoints > 0
           AND coalesce(u.received_at, c.created_at) < now() - t.collector_silent_after AS silent,
         c.endpoints > 0
           AND u.backlog_bytes >= t.backlog_near_capacity * u.backlog_max_bytes
           AS backlog_near_capacity,
         c.endpoints > 0 AND u.backlog_refused > 0 AS has_refused,
         c.endpoints > 0 AND u.backlog_discarded_files > 0 AS has_discarded,
         c.endpoints > 0 AND u.backlog_quarantined > 0 AS has_quarantined,
         u.config_digest, u.config_refused_digest, u.config_refusal_reason,
         c.endpoints > 0 AND u.config_refused_digest IS NOT NULL AS has_config_refused
  FROM c
  CROSS JOIN t
  LEFT JOIN LATERAL (
    SELECT upload_id, batch_id, collector_id, received_at, sent_at, backlog_events, backlog_bytes, backlog_batches, backlog_oldest, backlog_max_bytes, backlog_refused, backlog_discarded_files, backlog_quarantined, readings_inserted, readings_duplicate, readings_conflicting, missed_reads_inserted, missed_reads_duplicate, config_digest, config_refused_digest, config_refusal_reason FROM store.uploads u WHERE u.collector_id = c.collector_id
    ORDER BY u.received_at DESC, u.upload_id DESC LIMIT 1
  ) u ON true
  LEFT JOIN LATERAL (
    SELECT * FROM store.batches b WHERE b.collector_id = c.collector_id
    ORDER BY b.received_at DESC LIMIT 1
  ) b ON true
  LEFT JOIN LATERAL (
    SELECT sum(n) AS missed, jsonb_object_agg(reason::text, n) AS by_reason
    FROM (SELECT x.reason, count(*) AS n FROM store.missed_reads x
          WHERE x.collector_id = c.collector_id AND x.read_at > now() - t.lookback
          GROUP BY x.reason) g
  ) m ON true;

COMMENT ON COLUMN health.collectors.clock_source IS 'As of the batch first received last; a draining backlog sends its oldest batches first.';

GRANT SELECT ON TABLE health.collectors TO monitor;

-- Per collector, its last clock check (by its own clock), and its last
-- answered one: when the server sent it, by the server's clock, and the
-- offset and error bound it gave; and the offset bound of its latest upload.
-- Unchecked: in service, not silent, and no answered check in the last 48
-- hours by the server's clock (counted from registration when it has none).
-- The server is shown with control characters as ?.
-- contract: central/test/clock.sql
CREATE VIEW health.collector_clocks AS
  SELECT c.collector_id, c.in_service,
         l.t1 AS last_check_at, l.outcome AS last_outcome,
         regexp_replace(l.server, '[[:cntrl:]]', '?', 'g') AS last_server, lr.reference AS last_reference,
         a.t3 AS last_answered_at, a.offset_seconds, a.error_bound_seconds,
         u.offset_at_most_seconds AS upload_offset_at_most_seconds,
         c.in_service AND NOT c.silent
           AND coalesce(a.t3, s.created_at) < now() - interval '48 hours' AS unchecked
  FROM health.collectors c
  JOIN store.collectors s ON s.id = c.collector_id
  LEFT JOIN LATERAL (
    SELECT * FROM store.clock_checks x WHERE x.collector_id = c.collector_id
    ORDER BY x.t1 DESC LIMIT 1
  ) l ON true
  LEFT JOIN store.clock_check_references lr ON (lr.collector_id, lr.t1) = (l.collector_id, l.t1)
  LEFT JOIN LATERAL (
    SELECT * FROM store.clock_offsets x WHERE x.collector_id = c.collector_id
    ORDER BY x.t1 DESC LIMIT 1
  ) a ON true
  LEFT JOIN LATERAL (
    SELECT * FROM store.upload_clock_offsets x WHERE x.collector_id = c.collector_id
    ORDER BY x.received_at DESC, x.upload_id DESC LIMIT 1
  ) u ON true;

GRANT SELECT ON TABLE health.collector_clocks TO monitor;

-- Per registered target copied now (it and its endpoint in service, copy
-- on, no other system polling it), as registered now: since when its
-- endpoint has copied without a break; the meter its last meter-clock read
-- at the unit's address found, NULL until one comes; when that serial's
-- clock was first read anywhere, which is when a collector able to copy
-- first saw it; the meter's offset from UTC as that read measured it, its
-- zone and drift together; and its collector's last upload. Each a keyed
-- lookup: the place and serial keys of store.meter_clock_reads, the
-- collector key of store.uploads.
-- contract: central/test/health.sql
CREATE VIEW health.copy_targets AS
  SELECT g.endpoint_id, g.unit_id, e.collector_id, e.host, e.port, g.profile,
         c.meter_serial AS serial,
         coalesce(
           (SELECT max(upper(x.period)) FROM registry.endpoint_history x
            WHERE x.endpoint_id = g.endpoint_id
              AND NOT (x.in_service AND x.copy AND NOT x.polled_by_other_system)
              AND upper(x.period) <= now()),
           (SELECT min(x.valid_from) FROM registry.endpoint_versions x
            WHERE x.endpoint_id = g.endpoint_id)) AS copying_since,
         (SELECT min(f.collector_at) FROM store.meter_clock_reads f
          WHERE f.meter_serial = c.meter_serial) AS first_seen_at,
         c.collector_at AS clock_read_at,
         c.meter_time - (c.collector_at AT TIME ZONE 'UTC') AS meter_offset,
         (SELECT max(u.received_at) FROM store.uploads u WHERE u.collector_id = e.collector_id)
           AS last_upload_at
  FROM registry.target_history g
  JOIN registry.endpoint_history e ON e.endpoint_id = g.endpoint_id AND e.period @> now()
  LEFT JOIN LATERAL (
    SELECT m.meter_serial, m.collector_at, m.meter_time FROM store.meter_clock_reads m
    WHERE (m.collector_id, m.endpoint_host, m.endpoint_port, m.unit_id)
          = (e.collector_id, e.host, e.port, g.unit_id)
    ORDER BY m.collector_at DESC
    LIMIT 1
  ) c ON true
  WHERE g.period @> now() AND g.in_service AND e.in_service AND e.copy
    AND NOT e.polled_by_other_system;

GRANT SELECT ON TABLE health.copy_targets TO monitor;

-- Per copied target whose meter is known, and per store its profile copies
-- with a behind_after: the store is behind when no entry of the serial is
-- stamped later than behind_after before the meter's clock at the
-- collector's last upload, and the endpoint copied and the meter was seen
-- since before then. A 440's snapshot is judged in health.missed_snapshots
-- instead; a profile not listed here is not judged. behind is an existence
-- test by serial, store and stamp range over the chunks that range reaches;
-- newest_entry walks each of the profile's register keys for that store, by
-- key, from the newest.
-- contract: central/test/health.sql
CREATE VIEW health.copy_stores AS
  WITH t AS (SELECT collector_silent_after, meter_silent_intervals, backlog_near_capacity, lookback, set_at, endpoint_error_rate, snapshot_missed_margin, history_behind_after, snapshot_behind_after_elite_500, load_survey_behind_after_elite_440, load_survey_behind_after_elite_500 FROM health.thresholds),
  k AS (
    SELECT k.*,
           (k.last_upload_at AT TIME ZONE 'UTC') + k.meter_offset AS meter_at_upload,
           (greatest(k.copying_since, k.first_seen_at) AT TIME ZONE 'UTC') + k.meter_offset
             AS meter_since
    FROM health.copy_targets k
    WHERE k.serial IS NOT NULL
  )
  SELECT k.serial, s.store, k.endpoint_id, k.unit_id, k.collector_id, k.host, k.port, k.profile,
         s.behind_after,
         (SELECT max(n.meter_time)
          FROM (SELECT DISTINCT p.register_key FROM store.profile_stored p
                WHERE p.profile = k.profile AND p.store = s.store) r
          CROSS JOIN LATERAL (
            SELECT e.meter_time FROM store.stored_entries e
            WHERE (e.meter_serial, e.store, e.register_key) = (k.serial, s.store, r.register_key)
            ORDER BY e.meter_time DESC
            LIMIT 1
          ) n) AS newest_entry,
         k.meter_at_upload,
         coalesce(k.meter_since < k.meter_at_upload - s.behind_after
                  AND NOT EXISTS (
                    SELECT FROM store.stored_entries e
                    WHERE e.meter_serial = k.serial AND e.store = s.store
                      AND e.meter_time >= k.meter_at_upload - s.behind_after),
                  false) AS behind
  FROM k
  CROSS JOIN t
  CROSS JOIN LATERAL (
    VALUES ('elite_440', 'history'::store.stored_store, t.history_behind_after),
           ('elite_440', 'load_survey', t.load_survey_behind_after_elite_440),
           ('elite_500', 'history', t.history_behind_after),
           ('elite_500', 'snapshot', t.snapshot_behind_after_elite_500),
           ('elite_500', 'load_survey', t.load_survey_behind_after_elite_500)
  ) s (profile, store, behind_after)
  WHERE s.profile = k.profile;

GRANT SELECT ON TABLE health.copy_stores TO monitor;

-- A 440 keeps one daily snapshot, stamped at its midnight and replaced at
-- the next, so a day whose snapshot was not copied is lost. Per copied 440
-- whose meter is known, each meter day missed: its snapshot taken (by the
-- meter's clock) after its endpoint began copying and the meter was first
-- seen; replaced at least snapshot_missed_margin before the collector's last
-- upload, as the meter's clock then read, so that upload could have carried
-- it; replaced within the lookback, so a missed day is listed for that long;
-- and no snapshot entry of the serial stamped that day. Clock reads and
-- uploads are taken from health.copy_targets; the entries are looked up by
-- serial, store and stamp range, within the day's chunk.
-- contract: central/test/health.sql
CREATE VIEW health.missed_snapshots AS
  WITH t AS (SELECT collector_silent_after, meter_silent_intervals, backlog_near_capacity, lookback, set_at, endpoint_error_rate, snapshot_missed_margin, history_behind_after, snapshot_behind_after_elite_500, load_survey_behind_after_elite_440, load_survey_behind_after_elite_500 FROM health.thresholds),
  k AS (
    SELECT k.*,
           (now() AT TIME ZONE 'UTC') + k.meter_offset AS meter_now,
           (k.last_upload_at AT TIME ZONE 'UTC') + k.meter_offset AS meter_at_upload,
           (greatest(k.copying_since, k.first_seen_at) AT TIME ZONE 'UTC') + k.meter_offset
             AS meter_since
    FROM health.copy_targets k
    WHERE k.profile = 'elite_440' AND k.serial IS NOT NULL
  )
  SELECT k.serial, k.endpoint_id, k.unit_id, k.collector_id, k.host, k.port,
         d::date AS meter_day, k.meter_offset, k.clock_read_at
  FROM k
  CROSS JOIN t
  CROSS JOIN LATERAL generate_series(
    date_trunc('day', k.meter_now - t.snapshot_missed_margin - t.lookback),
    k.meter_at_upload - t.snapshot_missed_margin - interval '1 day',
    interval '1 day') d
  -- LIMIT keeps this a lookup per day: as NOT EXISTS, the planner may join
  -- it against every snapshot entry instead.
  LEFT JOIN LATERAL (
    SELECT true AS copied FROM store.stored_entries s
    WHERE s.meter_serial = k.serial AND s.store = 'snapshot'
      AND s.meter_time >= d AND s.meter_time < d + interval '1 day'
    LIMIT 1
  ) s ON true
  WHERE d >= k.meter_since
    AND d + interval '1 day' > k.meter_now - t.snapshot_missed_margin - t.lookback
    AND s.copied IS NULL;

GRANT SELECT ON TABLE health.missed_snapshots TO monitor;

-- Per copied target whose meter is known: the stores health.copy_stores
-- finds behind, the snapshot days health.missed_snapshots finds missed, and
-- how often it is polled. Polled slowly when its copies fail and it is
-- polled less often than copy_failing_interval.
-- contract: central/test/health.sql
CREATE VIEW health.copy_meters AS
  WITH t AS (SELECT collector_silent_after, meter_silent_intervals, backlog_near_capacity, lookback, set_at, endpoint_error_rate, snapshot_missed_margin, history_behind_after, snapshot_behind_after_elite_500, load_survey_behind_after_elite_440, load_survey_behind_after_elite_500, meter_clock_step_after, meter_clock_far_after, copy_failing_interval FROM health.thresholds),
  behind AS (
    SELECT serial, endpoint_id, unit_id, array_agg(store ORDER BY store) AS stores
    FROM health.copy_stores WHERE behind
    GROUP BY serial, endpoint_id, unit_id
  ),
  missed AS (
    SELECT serial, endpoint_id, unit_id, count(*) AS days
    FROM health.missed_snapshots
    GROUP BY serial, endpoint_id, unit_id
  ),
  k AS (
    SELECT k.serial, k.endpoint_id, k.unit_id, k.collector_id, k.host, k.port, k.profile,
           coalesce(g.interval_ms, e.interval_ms) * interval '1 millisecond' AS expected_interval,
           b.stores AS behind_stores, coalesce(m.days, 0) AS missed_snapshot_days
    FROM health.copy_targets k
    JOIN registry.target_history g
      ON (g.endpoint_id, g.unit_id) = (k.endpoint_id, k.unit_id) AND g.period @> now()
    JOIN registry.endpoint_history e ON e.endpoint_id = k.endpoint_id AND e.period @> now()
    LEFT JOIN behind b ON (b.serial, b.endpoint_id, b.unit_id) = (k.serial, k.endpoint_id, k.unit_id)
    LEFT JOIN missed m ON (m.serial, m.endpoint_id, m.unit_id) = (k.serial, k.endpoint_id, k.unit_id)
    WHERE k.serial IS NOT NULL
  )
  SELECT k.*, k.behind_stores IS NOT NULL OR k.missed_snapshot_days > 0 AS failing,
         (k.behind_stores IS NOT NULL OR k.missed_snapshot_days > 0)
           AND k.expected_interval > t.copy_failing_interval AS polled_slowly
  FROM k
  CROSS JOIN t;

GRANT SELECT ON TABLE health.copy_meters TO monitor;

-- Per registered endpoint, as registered now, its latency on each UTC day
-- that overlaps the lookback, at each address it had while in service on
-- that day, per bucket version (counts under different bounds do not merge).
-- The lookback's days are found by index on the day before any is merged:
-- the bound on d.day refers to nothing but the thresholds, so it reaches
-- into store.latency_endpoint_days.
-- contract: central/test/latency.sql
CREATE VIEW health.endpoint_latency AS
  WITH t AS (SELECT collector_silent_after, meter_silent_intervals, backlog_near_capacity, lookback, set_at, endpoint_error_rate FROM health.thresholds),
  periods AS (
    SELECT h.endpoint_id, h.collector_id, h.host, h.port,
           greatest(lower(h.period), now() - t.lookback) AS since, upper(h.period) AS until
    FROM registry.endpoint_history h
    CROSS JOIN t
    WHERE h.in_service AND h.period && tstzrange(now() - t.lookback, now())
      AND EXISTS (SELECT FROM registry.endpoint_history n
                  WHERE n.endpoint_id = h.endpoint_id AND n.period @> now())
  )
  SELECT DISTINCT p.endpoint_id, p.collector_id, p.host, p.port, d.day, d.buckets_version,
         d.meters, d.entries, d.answered, d.retries, d.timeouts, d.p50_ms, d.p90_ms, d.p99_ms,
         d.max_ms
  FROM periods p
  JOIN store.latency_endpoint_days d
    ON (d.collector_id, d.endpoint_host, d.endpoint_port) = (p.collector_id, p.host, p.port)
   AND d.day >= (p.since AT TIME ZONE 'UTC')::date
   AND (p.until IS NULL OR d.day::timestamp AT TIME ZONE 'UTC' < p.until)
  WHERE d.day >= ((now() - (SELECT lookback FROM health.thresholds)) AT TIME ZONE 'UTC')::date;

GRANT SELECT ON TABLE health.endpoint_latency TO monitor;

-- Per registered endpoint, as health.endpoint_latency gives it a row per UTC
-- day of the lookback and bucket version: its timeout now, what answered
-- (answered, retries, timeouts, p99, max), and the late replies its meters'
-- entries counted: late_entries of entries counted them, and late_data and
-- late_exceptions sum those; both NULL when none did.
-- contract: central/test/latency.sql
CREATE VIEW health.endpoint_timeouts AS
  WITH since AS (
    SELECT ((now() - lookback) AT TIME ZONE 'UTC')::date AS day FROM health.thresholds
  ), days AS (
    SELECT d.collector_id, d.endpoint_host, d.endpoint_port, d.day, d.buckets_version,
           count(d.late_data) AS late_entries, sum(d.late_data)::bigint AS late_data
    FROM store.latency_days d
    WHERE d.day >= (SELECT day FROM since)
    GROUP BY d.collector_id, d.endpoint_host, d.endpoint_port, d.day, d.buckets_version
  ), codes AS (
    SELECT d.collector_id, d.endpoint_host, d.endpoint_port, d.day, d.buckets_version,
           x.key AS code, sum((x.value #>> '{}')::bigint) AS n
    FROM store.latency_days d
    CROSS JOIN LATERAL jsonb_each(d.late_exceptions) x
    WHERE d.day >= (SELECT day FROM since)
    GROUP BY d.collector_id, d.endpoint_host, d.endpoint_port, d.day, d.buckets_version, x.key
  )
  SELECT l.endpoint_id, l.collector_id, l.host, l.port, l.day, l.buckets_version, now.timeout_ms,
         l.entries, l.answered, l.retries, l.timeouts, l.p99_ms, l.max_ms, k.late_entries,
         CASE WHEN k.late_entries > 0 THEN k.late_data END AS late_data,
         CASE WHEN k.late_entries > 0 THEN coalesce(
           (SELECT jsonb_object_agg(c.code, c.n)
            FROM codes c
            WHERE (c.collector_id, c.endpoint_host, c.endpoint_port, c.day, c.buckets_version)
                  = (l.collector_id, l.host, l.port, l.day, l.buckets_version)),
           '{}') END AS late_exceptions
  FROM health.endpoint_latency l
  JOIN registry.endpoint_history now ON now.endpoint_id = l.endpoint_id AND now.period @> now()
  JOIN days k
    ON (k.collector_id, k.endpoint_host, k.endpoint_port, k.day, k.buckets_version)
       = (l.collector_id, l.host, l.port, l.day, l.buckets_version);

GRANT SELECT ON TABLE health.endpoint_timeouts TO monitor;

-- Per registered endpoint, as registered now: the reads due at it within the
-- lookback, counted at each address it had while in service, from when it
-- had it. A read is a register: a reading, or a missed read. failed_reads
-- leaves out decode and profile_mismatch, which are the meter's answer, not
-- the read failing; error_rate is failed_reads over every read due, NULL when
-- none was. erroring: in service, read by us, and error_rate at or above
-- endpoint_error_rate.
-- contract: central/test/endpoints.sql
CREATE VIEW health.endpoints AS
  WITH t AS (SELECT collector_silent_after, meter_silent_intervals, backlog_near_capacity, lookback, set_at, endpoint_error_rate FROM health.thresholds),
  -- Each address an endpoint had while in service, over the part of the
  -- lookback it had it.
  periods AS (
    SELECT h.endpoint_id, h.collector_id, h.host, h.port,
           greatest(lower(h.period), now() - t.lookback) AS since, upper(h.period) AS until
    FROM registry.endpoint_history h
    CROSS JOIN t
    WHERE h.in_service AND h.period && tstzrange(now() - t.lookback, now())
  ),
  readings AS (
    SELECT p.endpoint_id, sum(r.n) AS n
    FROM periods p
    CROSS JOIN LATERAL (
      SELECT count(*) AS n FROM store.readings r
      WHERE (r.collector_id, r.endpoint_host, r.endpoint_port) = (p.collector_id, p.host, p.port)
        AND r.read_at >= p.since AND (p.until IS NULL OR r.read_at < p.until)
    ) r
    GROUP BY p.endpoint_id
  ),
  missed AS (
    SELECT p.endpoint_id, m.reason, sum(m.n) AS n
    FROM periods p
    CROSS JOIN LATERAL (
      SELECT x.reason, count(*) AS n FROM store.missed_reads x
      WHERE (x.collector_id, x.endpoint_host, x.endpoint_port) = (p.collector_id, p.host, p.port)
        AND x.read_at >= p.since AND (p.until IS NULL OR x.read_at < p.until)
      GROUP BY x.reason
    ) m
    GROUP BY p.endpoint_id, m.reason
  ),
  failures AS (
    SELECT m.endpoint_id, sum(m.n) AS missed_reads,
           coalesce(sum(m.n) FILTER (WHERE m.reason NOT IN ('decode', 'profile_mismatch')), 0)
             AS failed_reads,
           jsonb_object_agg(m.reason::text, m.n) AS missed_by_reason
    FROM missed m
    GROUP BY m.endpoint_id
  ),
  e AS MATERIALIZED (
    SELECT e.endpoint_id, e.collector_id, e.host, e.port, e.in_service, e.polled_by_other_system,
           coalesce(r.n, 0) AS readings, coalesce(f.missed_reads, 0) AS missed_reads,
           coalesce(f.missed_by_reason, '{}') AS missed_by_reason,
           coalesce(f.failed_reads, 0) AS failed_reads
    FROM registry.endpoint_history e
    LEFT JOIN readings r USING (endpoint_id)
    LEFT JOIN failures f USING (endpoint_id)
    WHERE e.period @> now()
  )
  SELECT e.endpoint_id, e.collector_id, e.host, e.port, e.in_service, e.polled_by_other_system,
         e.readings, e.missed_reads, e.missed_by_reason, e.failed_reads,
         round(e.failed_reads / nullif(e.readings + e.missed_reads, 0), 4) AS error_rate,
         e.in_service AND NOT e.polled_by_other_system AND e.failed_reads > 0
           AND e.failed_reads >= t.endpoint_error_rate * (e.readings + e.missed_reads) AS erroring
  FROM e
  CROSS JOIN t;

GRANT SELECT ON TABLE health.endpoints TO monitor;

-- The drops among readings in batches that arrived within the lookback:
-- each such reading against the one before it, and the reading after it
-- against it (a late batch can land under a reading already stored). Found
-- from the batches by arrival, their readings by batch, and the neighbours on
-- the readings key, never by a scan of the readings. OFFSET 0 keeps each
-- LATERAL step a lookup: pulled up, the lookback (a join, so unestimated)
-- would let the planner hash-join every reading instead. The serial is shown
-- cut to 100 characters, control characters as ?.
-- contract: central/test/energy.sql
CREATE VIEW health.energy_drops AS
  WITH arrived AS (
    SELECT r.*
    FROM health.thresholds t
    JOIN store.batches b ON b.received_at > now() - t.lookback
    CROSS JOIN LATERAL (
      SELECT q.meter_serial, q.register_key, q.read_at FROM store.readings q
      WHERE q.batch_id = b.batch_id
      OFFSET 0
    ) r
  ),
  later AS (
    SELECT * FROM arrived
    UNION
    SELECT n.*
    FROM arrived a
    CROSS JOIN LATERAL (
      SELECT q.meter_serial, q.register_key, q.read_at FROM store.readings q
      WHERE q.meter_serial = a.meter_serial AND q.register_key = a.register_key
        AND q.read_at > a.read_at
      ORDER BY q.read_at
      LIMIT 1
    ) n
  )
  SELECT regexp_replace(left(d.meter_serial, 100), '[[:cntrl:]]', '?', 'g') AS serial,
         d.register_key, d.previous_read_at, d.previous_value, d.previous_unit,
         d.previous_collector_id, d.previous_clock_source, d.previous_clock_last_sync_at,
         d.previous_grounded, d.read_at, d.value, d.unit, d.collector_id, d.clock_source,
         d.clock_last_sync_at, d.grounded, d.suspect
  FROM later l
  CROSS JOIN LATERAL (
    SELECT * FROM store.energy_drops d
    WHERE (d.meter_serial, d.register_key, d.read_at) = (l.meter_serial, l.register_key, l.read_at)
    OFFSET 0
  ) d;

GRANT SELECT ON TABLE health.energy_drops TO monitor;

-- Per meter-clock read, the collector's answered clock check nearest it
-- within 48 hours (as store.ungrounded_readings bounds a reading), and the
-- meter's offset from UTC that check gives: the meter's local time less the
-- collector's time corrected by the check's offset, its zone and error
-- together. No check within the bound: no offset.
-- contract: central/test/health.sql
CREATE VIEW health.meter_clock_offsets AS
  SELECT m.meter_serial AS serial, m.collector_id, m.endpoint_host AS host,
         m.endpoint_port AS port, m.unit_id, m.profile, m.collector_at, m.meter_time,
         c.t1 AS check_at, c.offset_seconds AS collector_offset_seconds,
         m.meter_time
           - ((m.collector_at + (c.offset_seconds || ' seconds')::interval) AT TIME ZONE 'UTC')
           AS meter_offset,
         m.batch_id
  FROM store.meter_clock_reads m
  LEFT JOIN LATERAL (
    SELECT o.t1, o.offset_seconds FROM store.clock_offsets o
    WHERE o.collector_id = m.collector_id
      AND o.t1 BETWEEN m.collector_at - interval '48 hours' AND m.collector_at + interval '48 hours'
    ORDER BY greatest(o.t1 - m.collector_at, m.collector_at - o.t1), o.t1
    LIMIT 1
  ) c ON true;

GRANT SELECT ON TABLE health.meter_clock_offsets TO monitor;

-- What monitor may read of them: every row.
-- contract: central/test/grants.sql
CREATE VIEW health.meter_clock_read_conflicts AS
  SELECT * FROM store.meter_clock_read_conflicts;

GRANT SELECT ON TABLE health.meter_clock_read_conflicts TO monitor;

-- What monitor may read of them: every row, with when its batch first
-- arrived.
-- contract: central/test/grants.sql
CREATE VIEW health.meter_clock_reads AS
  SELECT m.*, b.received_at
  FROM store.meter_clock_reads m JOIN store.batches b USING (batch_id);

GRANT SELECT ON TABLE health.meter_clock_reads TO monitor;

-- Per grounded meter-clock read that arrived within the lookback, its step
-- from the meter's previous grounded read (by serial, wherever it was read)
-- when that moved more than meter_clock_step_after: the clock was set or
-- stopped between the two reads. Found by arrival, so a weeks-late batch's
-- steps are listed when it comes.
-- contract: central/test/health.sql
CREATE VIEW health.meter_clock_steps AS
  WITH t AS (SELECT collector_silent_after, meter_silent_intervals, backlog_near_capacity, lookback, set_at, endpoint_error_rate, snapshot_missed_margin, history_behind_after, snapshot_behind_after_elite_500, load_survey_behind_after_elite_440, load_survey_behind_after_elite_500, meter_clock_step_after, meter_clock_far_after, copy_failing_interval FROM health.thresholds)
  SELECT o.serial, o.collector_id, o.host, o.port, o.unit_id,
         p.collector_at AS previous_read_at, p.meter_offset AS previous_meter_offset,
         o.collector_at AS read_at, o.meter_offset, o.meter_offset - p.meter_offset AS step,
         b.received_at
  FROM t
  JOIN store.batches b ON b.received_at > now() - t.lookback
  -- OFFSET 0 keeps this a lookup per batch: flattened, the planner may join
  -- every meter-clock read against the batches instead.
  CROSS JOIN LATERAL (
    SELECT * FROM health.meter_clock_offsets x WHERE x.batch_id = b.batch_id OFFSET 0
  ) o
  CROSS JOIN LATERAL (
    SELECT q.collector_at, q.meter_offset FROM health.meter_clock_offsets q
    WHERE q.serial = o.serial AND q.collector_at < o.collector_at AND q.meter_offset IS NOT NULL
    ORDER BY q.collector_at DESC
    LIMIT 1
  ) p
  WHERE greatest(o.meter_offset - p.meter_offset, p.meter_offset - o.meter_offset)
        > t.meter_clock_step_after;

GRANT SELECT ON TABLE health.meter_clock_steps TO monitor;

-- Per target in service now on an endpoint in service, the last grounded
-- meter-clock read at its address: the meter's offset, and its distance from
-- the median offset of its collector's meters. Far when that passes
-- meter_clock_far_after and the collector has at least three such meters:
-- the median of two is one of the two it would judge. Endpoints and targets'
-- reads are each found once: inlined, the planner rebuilt the endpoints for
-- every target and the medians for every meter, work quadratic in meters.
-- contract: central/test/health.sql
CREATE VIEW health.meter_clocks AS
  WITH t AS (SELECT collector_silent_after, meter_silent_intervals, backlog_near_capacity, lookback, set_at, endpoint_error_rate, snapshot_missed_margin, history_behind_after, snapshot_behind_after_elite_500, load_survey_behind_after_elite_440, load_survey_behind_after_elite_500, meter_clock_step_after, meter_clock_far_after, copy_failing_interval FROM health.thresholds),
  e AS MATERIALIZED (SELECT * FROM registry.endpoint_history WHERE period @> now()),
  k AS MATERIALIZED (
    SELECT g.endpoint_id, g.unit_id, e.collector_id, e.host, e.port, l.serial,
           l.collector_at AS read_at, l.meter_offset
    FROM registry.target_history g
    JOIN e ON e.endpoint_id = g.endpoint_id
    CROSS JOIN LATERAL (
      SELECT o.serial, o.collector_at, o.meter_offset FROM health.meter_clock_offsets o
      WHERE (o.collector_id, o.host, o.port, o.unit_id) = (e.collector_id, e.host, e.port, g.unit_id)
        AND o.meter_offset IS NOT NULL
      ORDER BY o.collector_at DESC
      LIMIT 1
    ) l
    WHERE g.period @> now() AND g.in_service AND e.in_service
  ),
  peers AS MATERIALIZED (
    SELECT collector_id, count(*) AS meters,
           percentile_disc(0.5) WITHIN GROUP (ORDER BY meter_offset) AS median_offset
    FROM k
    GROUP BY collector_id
  )
  SELECT k.serial, k.endpoint_id, k.unit_id, k.collector_id, k.host, k.port, k.read_at,
         k.meter_offset, p.meters AS collector_meters, p.median_offset AS collector_median_offset,
         k.meter_offset - p.median_offset AS from_median,
         p.meters >= 3
           AND greatest(k.meter_offset - p.median_offset, p.median_offset - k.meter_offset)
               > t.meter_clock_far_after AS far
  FROM k
  JOIN peers p USING (collector_id)
  CROSS JOIN t;

GRANT SELECT ON TABLE health.meter_clocks TO monitor;

-- Per meter serial, the latest names it reported; the latest record before
-- them whose names differ (previous), since the collector resends unchanged
-- names on every start; and the first record of the run that holds the latest
-- names (first_read_at, first_received_at), which a resend does not move. The
-- latest is by read_at, then address, so a tie is settled the same way every
-- time. The serial, product codes and host are shown cut to 100 characters,
-- control characters as ?.
-- contract: central/test/health.sql
CREATE VIEW health.meter_firmware AS
  WITH ranked AS (
    SELECT f.*, b.received_at,
           row_number() OVER (PARTITION BY f.meter_serial
                              ORDER BY f.read_at DESC, f.collector_id, f.endpoint_host,
                                       f.endpoint_port, f.unit_id) AS n,
           count(*) OVER (PARTITION BY f.meter_serial) AS records
    FROM store.firmware_reads f
    JOIN store.batches b USING (batch_id)
  ),
  latest AS (
    SELECT l.*,
           (SELECT min(r.n) FROM ranked r
            WHERE r.meter_serial = l.meter_serial
              AND (r.software, r.firmware_1, r.firmware_2, r.modbus_version)
                  IS DISTINCT FROM (l.software, l.firmware_1, l.firmware_2, l.modbus_version))
             AS previous_n
    FROM ranked l
    WHERE l.n = 1
  )
  SELECT regexp_replace(left(l.meter_serial, 100), '[[:cntrl:]]', '?', 'g') AS serial,
         regexp_replace(left(l.product_code, 100), '[[:cntrl:]]', '?', 'g') AS product_code,
         l.software, l.firmware_1, l.firmware_2, l.modbus_version, l.read_at, l.received_at,
         l.collector_id,
         regexp_replace(left(l.endpoint_host, 100), '[[:cntrl:]]', '?', 'g') AS endpoint_host,
         l.endpoint_port, l.unit_id,
         s.read_at AS first_read_at, s.received_at AS first_received_at,
         p.software AS previous_software, p.firmware_1 AS previous_firmware_1,
         p.firmware_2 AS previous_firmware_2, p.modbus_version AS previous_modbus_version,
         p.read_at AS previous_read_at,
         p.n IS NOT NULL AS changed
  FROM latest l
  LEFT JOIN ranked p ON p.meter_serial = l.meter_serial AND p.n = l.previous_n
  JOIN ranked s ON s.meter_serial = l.meter_serial
               AND s.n = coalesce(l.previous_n, l.records + 1) - 1;

GRANT SELECT ON TABLE health.meter_firmware TO monitor;

-- A missed read counts for the meter that reported the serial on it or, when
-- no serial was read, for the meter registered at its address now.
-- contract: central/test/health.sql
CREATE VIEW health.meters AS
  WITH t AS (SELECT collector_silent_after, meter_silent_intervals, backlog_near_capacity, lookback, set_at, endpoint_error_rate FROM health.thresholds),
  m AS (
    SELECT m.serial, m.in_service, m.endpoint_id, m.unit_id, g.profile, e.collector_id,
           e.host, e.port, e.polled_by_other_system,
           m.in_service AND g.in_service AND e.in_service AND NOT e.polled_by_other_system
             AS expected,
           coalesce(g.interval_ms, e.interval_ms) * interval '1 millisecond' AS expected_interval,
           coalesce(
             (SELECT max(upper(x.period)) FROM registry.meter_history x
              WHERE x.serial = m.serial AND NOT x.in_service AND upper(x.period) <= now()),
             (SELECT min(x.valid_from) FROM registry.meter_versions x WHERE x.serial = m.serial))
             AS in_service_since,
           (SELECT max(r.read_at) FROM store.readings r WHERE r.meter_serial = m.serial)
             AS last_reading_at
    FROM registry.meter_history m
    JOIN registry.target_history g
      ON (g.endpoint_id, g.unit_id) = (m.endpoint_id, m.unit_id) AND g.period @> now()
    JOIN registry.endpoint_history e ON e.endpoint_id = m.endpoint_id AND e.period @> now()
    WHERE m.period @> now()
  )
  SELECT m.serial, m.in_service, m.collector_id, m.endpoint_id, m.unit_id, m.profile,
         m.polled_by_other_system, m.expected, m.expected_interval, m.in_service_since,
         m.last_reading_at,
         coalesce(x.missed, 0) AS missed_reads, coalesce(x.by_reason, '{}') AS missed_by_reason,
         m.expected
           AND greatest(m.last_reading_at, m.in_service_since)
               < now() - t.meter_silent_intervals * m.expected_interval AS silent
  FROM m
  CROSS JOIN t
  LEFT JOIN LATERAL (
    SELECT sum(n) AS missed, jsonb_object_agg(reason::text, n) AS by_reason
    FROM (SELECT r.reason, count(*) AS n FROM store.missed_reads r
          WHERE r.read_at > now() - t.lookback
            AND (r.meter_serial = m.serial
                 OR (r.meter_serial IS NULL AND r.collector_id = m.collector_id
                     AND r.endpoint_host = m.host AND r.endpoint_port = m.port
                     AND r.unit_id = m.unit_id))
          GROUP BY r.reason) g
  ) x ON true;

GRANT SELECT ON TABLE health.meters TO monitor;

-- How many of its rounds each meter expected to be read was read within the
-- lookback, so a meter read now and then, and never silent long enough to be
-- flagged, still shows.
--
-- A round is a meter's readings run together: one more than half the meter's
-- interval after its previous reading starts the next. Each register has its
-- own read_at, and rounds fall on the collector's local wall clock, whose
-- zone is not registered, so neither one timestamp nor a fixed slot names a
-- round. A read on demand away from a round counts as one.
--
-- The window starts at the lookback or when the meter came into service,
-- whichever is later; rounds_due is how many whole intervals fit in it, at
-- the meter's interval now. Rounds a buffering collector has not uploaded yet
-- count as not read until they arrive.
-- contract: central/test/health.sql
CREATE VIEW health.meter_rounds AS
  WITH m AS (
    SELECT m.serial, m.collector_id, m.endpoint_id, m.unit_id, m.expected_interval,
           greatest(now() - t.lookback, m.in_service_since) AS since
    FROM health.meters m
    CROSS JOIN health.thresholds t
    WHERE m.expected
  )
  SELECT m.serial, m.collector_id, m.endpoint_id, m.unit_id, m.expected_interval, m.since,
         floor(extract(epoch FROM now() - m.since) / extract(epoch FROM m.expected_interval))::bigint
           AS rounds_due,
         coalesce(r.rounds, 0) AS rounds_read
  FROM m
  LEFT JOIN LATERAL (
    SELECT count(*) FILTER (WHERE x.previous IS NULL OR x.read_at - x.previous > m.expected_interval / 2)
             AS rounds
    FROM (SELECT r.read_at, lag(r.read_at) OVER (ORDER BY r.read_at) AS previous
          FROM store.readings r
          WHERE r.meter_serial = m.serial AND r.read_at >= m.since) x
  ) r ON true;

GRANT SELECT ON TABLE health.meter_rounds TO monitor;

-- Registered serials read within the lookback somewhere other than where the
-- registry placed them when the reading was taken: one row per serial and
-- place read. A reading from before the serial's first registry row is not
-- judged. The host is shown cut to 100 characters, control characters as ?.
-- contract: central/test/health.sql
CREATE VIEW health.misplaced_serials AS
  SELECT r.meter_serial AS serial, r.collector_id,
         regexp_replace(left(r.endpoint_host, 100), '[[:cntrl:]]', '?', 'g') AS endpoint_host,
         r.endpoint_port, r.unit_id,
         count(*) AS readings, max(r.read_at) AS last_reading_at,
         array_agg(DISTINCT format('%s unit %s', m.endpoint_id, m.unit_id)) AS registered_at
  FROM store.readings r
  CROSS JOIN health.thresholds t
  JOIN registry.meter_history m ON m.serial = r.meter_serial AND m.period @> r.read_at
  JOIN registry.endpoint_history e ON e.endpoint_id = m.endpoint_id AND e.period @> r.read_at
  WHERE r.read_at > now() - t.lookback
    AND (r.collector_id, r.endpoint_host, r.endpoint_port, r.unit_id)
        IS DISTINCT FROM (e.collector_id, e.host, e.port, m.unit_id)
  GROUP BY r.meter_serial, r.collector_id, r.endpoint_host, r.endpoint_port, r.unit_id;

GRANT SELECT ON TABLE health.misplaced_serials TO monitor;

-- Places (collector, host, port, unit) whose readings and missed reads within
-- the lookback carry more than one serial, registered or not: one row per
-- place and serial. A swap shows as one serial's sightings ending where the
-- next one's begin; two meters answering one address, as theirs
-- interleaving. Either is a fault in the field to look into, not something
-- to infer from here. The serial and host are shown cut to 100 characters,
-- control characters as ?.
-- contract: central/test/health.sql
CREATE VIEW health.place_serials AS
  WITH seen AS (
    SELECT r.meter_serial, r.collector_id, r.endpoint_host, r.endpoint_port, r.unit_id, r.read_at,
           true AS read
    FROM store.readings r
    CROSS JOIN health.thresholds t
    WHERE r.read_at > now() - t.lookback
    UNION ALL
    SELECT m.meter_serial, m.collector_id, m.endpoint_host, m.endpoint_port, m.unit_id, m.read_at,
           false
    FROM store.missed_reads m
    CROSS JOIN health.thresholds t
    WHERE m.read_at > now() - t.lookback AND m.meter_serial IS NOT NULL
  ),
  shared AS (
    SELECT collector_id, endpoint_host, endpoint_port, unit_id
    FROM seen
    GROUP BY collector_id, endpoint_host, endpoint_port, unit_id
    HAVING count(DISTINCT meter_serial) > 1
  )
  SELECT r.collector_id,
         regexp_replace(left(r.endpoint_host, 100), '[[:cntrl:]]', '?', 'g') AS endpoint_host,
         r.endpoint_port, r.unit_id,
         regexp_replace(left(r.meter_serial, 100), '[[:cntrl:]]', '?', 'g') AS serial,
         count(*) FILTER (WHERE r.read) AS readings,
         count(*) FILTER (WHERE NOT r.read) AS missed_reads,
         min(r.read_at) AS first_seen_at, max(r.read_at) AS last_seen_at
  FROM seen r
  JOIN shared s USING (collector_id, endpoint_host, endpoint_port, unit_id)
  GROUP BY r.collector_id, r.endpoint_host, r.endpoint_port, r.unit_id, r.meter_serial;

GRANT SELECT ON TABLE health.place_serials TO monitor;

-- Per registered target, as registered now: the meter placed there now, if
-- any, and the last reading and last missed read at its unit, whatever serial
-- they carry, at each address its endpoint had while in service. A target is
-- silent when no reading came for meter_silent_intervals × its interval while
-- it was expected to be read.
-- contract: central/test/health.sql
CREATE VIEW health.targets AS
  WITH t AS (SELECT collector_silent_after, meter_silent_intervals, backlog_near_capacity, lookback, set_at, endpoint_error_rate, snapshot_missed_margin, history_behind_after, snapshot_behind_after_elite_500, load_survey_behind_after_elite_440, load_survey_behind_after_elite_500 FROM health.thresholds),
  g AS (
    SELECT g.endpoint_id, g.unit_id, g.in_service, g.profile, e.collector_id, e.host, e.port,
           e.polled_by_other_system,
           g.in_service AND e.in_service AND NOT e.polled_by_other_system AS expected,
           coalesce(g.interval_ms, e.interval_ms) * interval '1 millisecond' AS expected_interval,
           coalesce(
             (SELECT max(upper(x.period)) FROM registry.target_history x
              WHERE (x.endpoint_id, x.unit_id) = (g.endpoint_id, g.unit_id) AND NOT x.in_service
                AND upper(x.period) <= now()),
             (SELECT min(x.valid_from) FROM registry.target_versions x
              WHERE (x.endpoint_id, x.unit_id) = (g.endpoint_id, g.unit_id)))
             AS in_service_since,
           (SELECT m.serial FROM registry.meter_history m
            WHERE (m.endpoint_id, m.unit_id) = (g.endpoint_id, g.unit_id) AND m.in_service
              AND m.period @> now()) AS serial
    FROM registry.target_history g
    JOIN registry.endpoint_history e ON e.endpoint_id = g.endpoint_id AND e.period @> now()
    WHERE g.period @> now()
  )
  SELECT g.endpoint_id, g.unit_id, g.in_service, g.collector_id, g.host, g.port, g.profile,
         g.serial, g.polled_by_other_system, g.expected, g.expected_interval, g.in_service_since,
         l.reading_at AS last_reading_at, l.missed_at AS last_missed_read_at,
         g.expected
           AND greatest(l.reading_at, g.in_service_since)
               < now() - t.meter_silent_intervals * g.expected_interval AS silent
  FROM g
  CROSS JOIN t
  LEFT JOIN LATERAL (
    -- Over every in-service period of the target's endpoint, at its address then.
    SELECT max(r.read_at) AS reading_at, max(x.read_at) AS missed_at
    FROM registry.endpoint_history a
    CROSS JOIN LATERAL (
      SELECT max(r.read_at) AS read_at FROM store.readings r
      WHERE (r.collector_id, r.endpoint_host, r.endpoint_port, r.unit_id)
            = (a.collector_id, a.host, a.port, g.unit_id)
        AND r.read_at >= lower(a.period) AND (upper(a.period) IS NULL OR r.read_at < upper(a.period))
    ) r
    CROSS JOIN LATERAL (
      SELECT max(x.read_at) AS read_at FROM store.missed_reads x
      WHERE (x.collector_id, x.endpoint_host, x.endpoint_port, x.unit_id)
            = (a.collector_id, a.host, a.port, g.unit_id)
        AND x.read_at >= lower(a.period) AND (upper(a.period) IS NULL OR x.read_at < upper(a.period))
    ) x
    WHERE a.endpoint_id = g.endpoint_id AND a.in_service
  ) l ON true;

GRANT SELECT ON TABLE health.targets TO monitor;

-- Serials not in the registry, per place (collector, host, port, unit) read
-- within the lookback. While no serial is registered, as in the first poll of
-- all meters, this is the only way to see one serial reported from two
-- places: two meters with one serial (a factory default, blank padding, or
-- the 440 and 500 lines overlapping), one meter reachable two ways, or a
-- move. A registered serial read away from its place is in
-- health.misplaced_serials. The serial and host are shown cut to 100
-- characters, control characters as ?.
-- contract: central/test/health.sql
CREATE VIEW health.unregistered_serial_places AS
  SELECT regexp_replace(left(r.meter_serial, 100), '[[:cntrl:]]', '?', 'g') AS serial,
         r.collector_id,
         regexp_replace(left(r.endpoint_host, 100), '[[:cntrl:]]', '?', 'g') AS endpoint_host,
         r.endpoint_port, r.unit_id,
         count(*) AS readings, max(r.read_at) AS last_reading_at
  FROM store.readings r
  CROSS JOIN health.thresholds t
  WHERE r.read_at > now() - t.lookback
    AND NOT EXISTS (SELECT FROM registry.meters m WHERE m.serial = r.meter_serial)
  GROUP BY r.meter_serial, r.collector_id, r.endpoint_host, r.endpoint_port, r.unit_id;

GRANT SELECT ON TABLE health.unregistered_serial_places TO monitor;

-- The serial is shown cut to 100 characters, control characters as ?.
-- contract: central/test/health.sql
CREATE VIEW health.unregistered_serials AS
  SELECT regexp_replace(left(r.meter_serial, 100), '[[:cntrl:]]', '?', 'g') AS serial,
         count(*) AS readings, max(r.read_at) AS last_reading_at,
         array_agg(DISTINCT r.collector_id ORDER BY r.collector_id) AS collectors
  FROM store.readings r
  CROSS JOIN health.thresholds t
  WHERE r.read_at > now() - t.lookback
    AND NOT EXISTS (SELECT FROM registry.meters m WHERE m.serial = r.meter_serial)
  GROUP BY r.meter_serial;

GRANT SELECT ON TABLE health.unregistered_serials TO monitor;

-- One row per problem: (kind, subject) names it, detail describes it now.
-- A problem is reported where the fault is: an endpoint whose every expected
-- unit is silent, behind a collector that is not, is one endpoint row, its
-- targets, meters and error rate not listed beside it. The kinds, and what
-- each holds back: central/README.md.
-- contract: central/test/health.sql, central/test/collector_config.sql,
--   central/test/endpoints.sql
CREATE VIEW health.problems AS
  WITH collectors AS MATERIALIZED (SELECT * FROM health.collectors),
  targets AS MATERIALIZED (
    SELECT g.*, coalesce(g.last_reading_at >= g.in_service_since, false) AS was_read
    FROM health.targets g
  ),
  silent_endpoints AS MATERIALIZED (
    SELECT g.endpoint_id, g.collector_id, g.host, g.port, count(*) AS units,
           max(g.last_reading_at) FILTER (WHERE g.was_read) AS last_reading_at,
           max(g.last_missed_read_at) AS last_missed_read_at,
           min(g.expected_interval) AS expected_interval
    FROM targets g
    JOIN collectors c USING (collector_id)
    WHERE g.expected AND NOT c.silent
    GROUP BY g.endpoint_id, g.collector_id, g.host, g.port
    HAVING bool_and(g.silent)
  ),
  erroring_endpoints AS MATERIALIZED (
    SELECT e.* FROM health.endpoints e
    WHERE e.erroring
      AND NOT EXISTS (SELECT FROM silent_endpoints s WHERE s.endpoint_id = e.endpoint_id)
  ),
  closing AS MATERIALIZED (
    SELECT p.endpoint_id, p.collector_id, p.host, p.port, m.read_at AS closed_at,
           r.read_at AS last_reading_at, t.lookback
    FROM (SELECT endpoint_id, collector_id, host, port FROM silent_endpoints
          UNION ALL
          SELECT endpoint_id, collector_id, host, port FROM erroring_endpoints) p
    CROSS JOIN health.thresholds t
    CROSS JOIN LATERAL (
      SELECT x.read_at, x.reason, x.detail FROM store.missed_reads x
      WHERE (x.collector_id, x.endpoint_host, x.endpoint_port) = (p.collector_id, p.host, p.port)
        AND x.read_at >= now() - t.lookback
      ORDER BY x.read_at DESC
      LIMIT 1
    ) m
    CROSS JOIN LATERAL (
      SELECT max(x.read_at) AS read_at FROM store.readings x
      WHERE (x.collector_id, x.endpoint_host, x.endpoint_port) = (p.collector_id, p.host, p.port)
        AND x.read_at >= now() - t.lookback
    ) r
    WHERE m.reason = 'unreachable' AND m.detail = 'closed'
      AND (r.read_at IS NULL OR r.read_at < m.read_at)
  )
  SELECT 'collector_silent' AS kind, c.collector_id AS subject,
         c.collector_id, NULL::text AS endpoint_id, NULL::text AS host, NULL::integer AS port,
         NULL::smallint AS unit_id, NULL::text AS serial,
         format('no upload since %s (%s endpoints in service)',
                coalesce(c.last_upload_at::text, 'it was registered'), c.endpoints) AS detail
  FROM collectors c WHERE c.silent
  UNION ALL
  SELECT 'backlog_near_capacity', c.collector_id, c.collector_id, NULL, NULL, NULL, NULL, NULL,
         format('backlog %s of %s bytes (%s%%), oldest %s', c.backlog_bytes, c.backlog_max_bytes,
                round(c.backlog_used * 100, 1), c.backlog_oldest)
  FROM collectors c WHERE c.backlog_near_capacity
  UNION ALL
  SELECT 'backlog_refused', c.collector_id, c.collector_id, NULL, NULL, NULL, NULL, NULL,
         format('%s events refused since the collector started', c.backlog_refused)
  FROM collectors c WHERE c.has_refused
  UNION ALL
  SELECT 'backlog_discarded', c.collector_id, c.collector_id, NULL, NULL, NULL, NULL, NULL,
         format('%s .discarded files in the buffer', c.backlog_discarded_files)
  FROM collectors c WHERE c.has_discarded
  UNION ALL
  SELECT 'backlog_quarantined', c.collector_id, c.collector_id, NULL, NULL, NULL, NULL, NULL,
         format('%s batches in quarantine', c.backlog_quarantined)
  FROM collectors c WHERE c.has_quarantined
  UNION ALL
  SELECT 'config_refused', c.collector_id, c.collector_id, NULL, NULL, NULL, NULL, NULL,
         format('refused the served config %s (%s); still applying %s', c.config_refused_digest,
                regexp_replace(c.config_refusal_reason, '[[:cntrl:]]', '?', 'g'), c.config_digest)
  FROM collectors c WHERE c.has_config_refused
  UNION ALL
  SELECT 'clock_unchecked', k.collector_id, k.collector_id, NULL, NULL, NULL, NULL, NULL,
         CASE WHEN k.last_check_at IS NULL THEN 'no clock check since it was registered'
         ELSE format('no answered clock check since %s; the last check, at %s by its clock, '
                     || 'was %s from %s',
                     coalesce(k.last_answered_at::text, 'it was registered'), k.last_check_at,
                     k.last_outcome || CASE WHEN k.last_outcome = 'kiss_of_death'
                                            THEN ' ' || k.last_reference ELSE '' END,
                     k.last_server)
         END
  FROM health.collector_clocks k WHERE k.unchecked
  UNION ALL
  SELECT CASE WHEN e.last_reading_at IS NULL THEN 'endpoint_never_read' ELSE 'endpoint_silent' END,
         e.endpoint_id, e.collector_id, e.endpoint_id, e.host, e.port, NULL, NULL,
         format('no reading from %s since %s (expected every %s; %s), at %s:%s via %s',
                CASE WHEN e.units = 1 THEN 'its one unit' ELSE format('any of its %s units', e.units)
                END,
                coalesce(e.last_reading_at::text,
                         CASE WHEN e.units = 1 THEN 'it came into service'
                              ELSE 'they came into service' END),
                e.expected_interval,
                coalesce('last missed read ' || e.last_missed_read_at, 'no missed read'),
                e.host, e.port, e.collector_id)
  FROM silent_endpoints e
  WHERE NOT EXISTS (SELECT FROM closing k WHERE k.endpoint_id = e.endpoint_id)
  UNION ALL
  SELECT 'endpoint_closes_connections', e.endpoint_id, e.collector_id, e.endpoint_id, e.host,
         e.port, NULL, NULL,
         format('took the last connection and closed it before sending a byte, at %s; '
                || 'no reading %s; at %s:%s via %s',
                e.closed_at, coalesce('since ' || e.last_reading_at, 'within ' || e.lookback),
                e.host, e.port, e.collector_id)
  FROM closing e
  UNION ALL
  SELECT CASE WHEN g.was_read THEN 'target_silent' ELSE 'target_never_read' END,
         format('%s unit %s', g.endpoint_id, g.unit_id),
         g.collector_id, g.endpoint_id, g.host, g.port, g.unit_id, g.serial,
         format('no reading since %s (expected every %s; %s), at %s:%s unit %s '
                || 'via %s, profile %s, %s',
                CASE WHEN g.was_read THEN g.last_reading_at::text ELSE 'it came into service' END,
                g.expected_interval,
                coalesce('last missed read ' || g.last_missed_read_at, 'no missed read'),
                g.host, g.port, g.unit_id, g.collector_id, g.profile,
                coalesce('meter ' || g.serial, 'no meter placed'))
  FROM targets g
  JOIN collectors c USING (collector_id)
  WHERE g.silent AND NOT c.silent
    AND NOT EXISTS (SELECT FROM silent_endpoints e WHERE e.endpoint_id = g.endpoint_id)
  UNION ALL
  SELECT CASE WHEN m.last_reading_at >= m.in_service_since THEN 'meter_silent'
              ELSE 'meter_never_read' END,
         m.serial, m.collector_id, m.endpoint_id, g.host, g.port, m.unit_id, m.serial,
         format('no reading since %s (expected every %s), on %s unit %s, collector %s',
                CASE WHEN m.last_reading_at >= m.in_service_since THEN m.last_reading_at::text
                     ELSE 'it came into service' END,
                m.expected_interval, m.endpoint_id, m.unit_id, m.collector_id)
  FROM health.meters m
  JOIN collectors c USING (collector_id)
  JOIN targets g USING (endpoint_id, unit_id)
  WHERE m.silent AND NOT c.silent AND NOT g.silent
  UNION ALL
  SELECT 'endpoint_errors', e.endpoint_id, e.collector_id, e.endpoint_id, e.host, e.port, NULL,
         NULL,
         format('%s of %s reads failed (%s%%) within %s, missed by reason %s, at %s:%s via %s',
                e.failed_reads, e.readings + e.missed_reads, round(e.error_rate * 100, 2),
                t.lookback, e.missed_by_reason, e.host, e.port, e.collector_id)
  FROM erroring_endpoints e
  CROSS JOIN health.thresholds t
  WHERE NOT EXISTS (SELECT FROM closing k WHERE k.endpoint_id = e.endpoint_id)
  UNION ALL
  SELECT 'unregistered_serial', u.serial, NULL, NULL, NULL, NULL, NULL, u.serial,
         format('%s readings, the last at %s, from %s', u.readings, u.last_reading_at,
                array_to_string(u.collectors, ', '))
  FROM health.unregistered_serials u
  UNION ALL
  SELECT 'misplaced_serial', p.serial, NULL, NULL, NULL, NULL, NULL, p.serial,
         string_agg(format('%s readings, the last at %s, at %s:%s unit %s via %s (registered at %s)',
                           p.readings, p.last_reading_at, p.endpoint_host, p.endpoint_port,
                           p.unit_id, p.collector_id, array_to_string(p.registered_at, ', ')),
                    '; ' ORDER BY p.collector_id, p.endpoint_host, p.endpoint_port, p.unit_id)
  FROM health.misplaced_serials p
  GROUP BY p.serial
  UNION ALL
  SELECT 'serial_at_several_places', u.serial, NULL, NULL, NULL, NULL, NULL, u.serial,
         string_agg(format('%s readings, the last at %s, at %s:%s unit %s via %s',
                           u.readings, u.last_reading_at, u.endpoint_host, u.endpoint_port,
                           u.unit_id, u.collector_id),
                    '; ' ORDER BY u.collector_id, u.endpoint_host, u.endpoint_port, u.unit_id)
  FROM health.unregistered_serial_places u
  GROUP BY u.serial
  HAVING count(*) > 1
  UNION ALL
  SELECT 'several_serials_at_place',
         format('%s:%s unit %s via %s', s.endpoint_host, s.endpoint_port, s.unit_id, s.collector_id),
         s.collector_id, NULL, s.endpoint_host, s.endpoint_port, s.unit_id, NULL,
         string_agg(format('%s: %s readings, %s missed reads, from %s to %s', s.serial,
                           s.readings, s.missed_reads, s.first_seen_at, s.last_seen_at),
                    '; ' ORDER BY s.first_seen_at, s.serial)
  FROM health.place_serials s
  GROUP BY s.collector_id, s.endpoint_host, s.endpoint_port, s.unit_id
  UNION ALL
  SELECT 'firmware_changed', f.serial, f.collector_id, NULL, f.endpoint_host, f.endpoint_port,
         f.unit_id, f.serial,
         format('software %s, firmware %s / %s, modbus %s (read %s) became '
                || 'software %s, firmware %s / %s, modbus %s (read %s), at %s:%s unit %s via %s',
                coalesce(f.previous_software, '(none)'), coalesce(f.previous_firmware_1, '(none)'),
                coalesce(f.previous_firmware_2, '(none)'),
                coalesce(f.previous_modbus_version, '(none)'), f.previous_read_at,
                coalesce(f.software, '(none)'), coalesce(f.firmware_1, '(none)'),
                coalesce(f.firmware_2, '(none)'), coalesce(f.modbus_version, '(none)'), f.first_read_at,
                f.endpoint_host, f.endpoint_port, f.unit_id, f.collector_id)
  FROM health.meter_firmware f
  CROSS JOIN health.thresholds t
  WHERE f.changed AND f.first_received_at > now() - t.lookback
  UNION ALL
  SELECT 'energy_backwards', e.serial, NULL, NULL, NULL, NULL, NULL, e.serial,
         string_agg(format('%s %s %s at %s (%s) after %s %s at %s (%s)%s',
                           e.register_key, e.value, e.unit, e.read_at,
                           e.collector_id || ', clock ' || e.clock_source
                           || CASE WHEN e.grounded THEN ', checked' ELSE ', unchecked' END,
                           e.previous_value, e.previous_unit, e.previous_read_at,
                           e.previous_collector_id || ', clock ' || e.previous_clock_source
                           || CASE WHEN e.previous_grounded THEN ', checked' ELSE ', unchecked' END,
                           CASE WHEN e.suspect THEN ', suspect: no clock check grounds either'
                                ELSE '' END),
                    '; ' ORDER BY e.register_key, e.read_at)
  FROM health.energy_drops e
  GROUP BY e.serial
  UNION ALL
  SELECT 'snapshot_missed', m.serial, m.collector_id, m.endpoint_id, m.host, m.port, m.unit_id,
         m.serial,
         format('no snapshot copied for meter day %s, now replaced on the meter; its clock read '
                || '%s from UTC at %s; at %s:%s unit %s via %s',
                string_agg(m.meter_day::text, ', ' ORDER BY m.meter_day), m.meter_offset,
                m.clock_read_at, m.host, m.port, m.unit_id, m.collector_id)
  FROM health.missed_snapshots m
  GROUP BY m.serial, m.meter_offset, m.clock_read_at, m.endpoint_id, m.host, m.port, m.unit_id,
           m.collector_id
  UNION ALL
  SELECT 'copy_behind', format('%s %s', s.serial, s.store),
         s.collector_id, s.endpoint_id, s.host, s.port, s.unit_id, s.serial,
         format('newest %s entry copied %s, more than %s before the meter''s clock at the last '
                || 'upload (%s); at %s:%s unit %s via %s, profile %s',
                s.store, coalesce(s.newest_entry::text, 'none'), s.behind_after,
                s.meter_at_upload, s.host, s.port, s.unit_id, s.collector_id, s.profile)
  FROM health.copy_stores s
  WHERE s.behind
  UNION ALL
  SELECT 'meter_clock_step', s.serial, NULL, NULL, NULL, NULL, NULL, s.serial,
         string_agg(format('clock moved %s between %s and %s (%s to %s from UTC), at %s:%s unit %s '
                           || 'via %s',
                           s.step, s.previous_read_at, s.read_at, s.previous_meter_offset,
                           s.meter_offset, s.host, s.port, s.unit_id, s.collector_id),
                    '; ' ORDER BY s.read_at)
  FROM health.meter_clock_steps s
  GROUP BY s.serial
  UNION ALL
  SELECT 'meter_clock_far', k.serial, k.collector_id, k.endpoint_id, k.host, k.port, k.unit_id,
         k.serial,
         format('clock %s from UTC at %s, %s from the median of the %s meters on %s; '
                || 'at %s:%s unit %s',
                k.meter_offset, k.read_at, k.from_median, k.collector_meters, k.collector_id,
                k.host, k.port, k.unit_id)
  FROM health.meter_clocks k
  WHERE k.far
  UNION ALL
  SELECT 'copy_failing_polled_slowly', m.serial, m.collector_id, m.endpoint_id, m.host, m.port,
         m.unit_id, m.serial,
         format('copies failing (%s) while polled every %s, less often than %s; at %s:%s unit %s '
                || 'via %s, profile %s',
                concat_ws(', ', 'behind: ' || array_to_string(m.behind_stores, ', '),
                          CASE WHEN m.missed_snapshot_days > 0
                               THEN m.missed_snapshot_days || ' snapshot days missed' END),
                m.expected_interval, t.copy_failing_interval, m.host, m.port, m.unit_id,
                m.collector_id, m.profile)
  FROM health.copy_meters m
  CROSS JOIN health.thresholds t
  WHERE m.polled_slowly;

GRANT SELECT ON TABLE health.problems TO monitor;

-- What monitor may read of them: every row, with when its batch first
-- arrived, so a late copy is found by arrival. The future minkanakku role
-- reads all four too, a widening of its interface; it is not built here.
-- contract: central/test/grants.sql
CREATE VIEW health.stored_entries AS
  SELECT s.*, b.received_at
  FROM store.stored_entries s JOIN store.batches b USING (batch_id);

GRANT SELECT ON TABLE health.stored_entries TO monitor;

-- What monitor may read of them: every row.
-- contract: central/test/grants.sql
CREATE VIEW health.stored_entry_conflicts AS
  SELECT * FROM store.stored_entry_conflicts;

GRANT SELECT ON TABLE health.stored_entry_conflicts TO monitor;


-- ==== seed rows ============================================================

-- The health views' first thresholds; later sets are added rows (admin).
INSERT INTO registry.health_thresholds
  (collector_silent_after, meter_silent_intervals, backlog_near_capacity, lookback,
   endpoint_error_rate, snapshot_missed_margin, history_behind_after,
   snapshot_behind_after_elite_500, load_survey_behind_after_elite_440,
   load_survey_behind_after_elite_500, meter_clock_step_after, meter_clock_far_after,
   copy_failing_interval)
VALUES
  (interval '1 hour', 4, 0.8, interval '1 day',
   0.05, interval '1 hour', interval '62 days',
   interval '14 days', interval '7 days',
   interval '30 days', interval '5 minutes', interval '15 minutes',
   interval '30 minutes');

-- migrate:down
-- Forward only: a rollback would drop raw data. Undo with a new migration.
