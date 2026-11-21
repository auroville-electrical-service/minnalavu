-- migrate:up

-- Copy fills (ADR 0025): a collector's nightly copy keeps its own high-water
-- mark, so entries the store lacks behind that mark (a buffer segment lost
-- after it was accepted, a store moved or restored) are found by
-- admin.copy_holes and filled by a request of kind fill_copies, made by the
-- operator with admin.request_fill. The collector copies what its meters
-- hold of the request's range, sending the entries with the request's id,
-- and one fill result per meter and store saying what of the range the
-- meter no longer held. Requests, their ranges and what answered them are
-- a record: rows are only ever added.

ALTER TYPE jobs.kind ADD VALUE 'fill_copies';

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
COMMENT ON COLUMN jobs.request_fill_results.gone_before IS
  'Entries of the range stamped before this were no longer on the meter; NULL when it held entries older than the range''s start.';

DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['request_fills', 'request_fill_stores', 'request_stored_entries',
                           'request_fill_results'] LOOP
    EXECUTE format(
      'CREATE TRIGGER refuse_change BEFORE UPDATE OR DELETE ON jobs.%I
         FOR EACH ROW EXECUTE FUNCTION jobs.refuse_change()', t);
    EXECUTE format(
      'CREATE TRIGGER refuse_truncate BEFORE TRUNCATE ON jobs.%I
         FOR EACH STATEMENT EXECUTE FUNCTION jobs.refuse_change()', t);
  END LOOP;
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
CREATE FUNCTION admin.request_fill(collector_id text, meters text[], stores text[],
                                   from_time timestamp, to_time timestamp, requester text,
                                   expires_after interval)
RETURNS uuid
LANGUAGE plpgsql AS $$
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
$$;

-- Each request as of now(), as in 0012_read_requests.sql, with what came for
-- a fill: its entries linked and its results. A fill is answered once every
-- meter and store it named has a result; a read on demand, once anything
-- came for it.
-- contract: central/test/requests.sql, central/test/fills.sql
CREATE OR REPLACE VIEW jobs.request_status AS
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

-- A collector's requests neither answered nor expired, oldest first, as the
-- ingest answer lists them; NULL when there are none. A fill also names its
-- stores and its range, as meter times.
CREATE OR REPLACE FUNCTION jobs.pending(collector text) RETURNS jsonb
LANGUAGE sql STABLE AS $$
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

-- contract: central/test/schema.sql
CREATE FUNCTION store.check_fill_result(v jsonb, path text) RETURNS void
LANGUAGE plpgsql AS $$
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

-- A checked batch's fill results as rows; none when it carries none.
CREATE FUNCTION store.batch_fill_results(b jsonb)
RETURNS TABLE (
  request_id uuid, meter_serial text, store store.stored_store, gone_before timestamp,
  finished_at timestamptz, endpoint_host text, endpoint_port integer, unit_id smallint
)
LANGUAGE sql STABLE AS $$
  SELECT (r ->> 'request_id')::uuid, r ->> 'meter_serial', (r ->> 'store')::store.stored_store,
         (r ->> 'gone_before')::timestamp, (r ->> 'finished_at')::timestamptz,
         r -> 'endpoint' ->> 'host', (r -> 'endpoint' ->> 'port')::numeric::integer,
         (r ->> 'unit_id')::numeric::smallint
  FROM jsonb_array_elements(coalesce(b -> 'fill_results', '[]')) r
$$;

-- Link a checked batch's stored entries and fill results to the calling
-- collector's fill request: an entry of a meter and store it named, stamped
-- in its range; a result of a meter and store it named, once (a resent
-- result is a duplicate, and the first stands). Returns the fill results'
-- counts: received, inserted, duplicate, and unlinked (not the caller's
-- request, or a meter or store it did not name).
-- contract: central/test/fills.sql
CREATE FUNCTION jobs.link_fills(b jsonb, caller text, batch uuid) RETURNS jsonb
LANGUAGE plpgsql AS $$
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

-- As in 0012_read_requests.sql, and a request id on a stored entry or a fill
-- result that is not the caller's is unknown too.
-- contract: central/test/requests.sql, central/test/fills.sql
CREATE OR REPLACE FUNCTION jobs.link_batch(b jsonb, caller text, batch uuid) RETURNS uuid[]
LANGUAGE plpgsql AS $$
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

-- Holes in what the store holds of each copied meter's stores, for the
-- operator's judgement (ADR 0025): per target copied now whose meter is
-- known (health.copy_targets) and per store its profile copies, each slot (a
-- day; a month for history, by the meter's clock) from since, or from the
-- store's oldest entry of the serial if later, up to its newest, that holds
-- no entry. A store with no entry of the serial has no holes: it is behind
-- (health.copy_stores). gone: a fill result showed the meter no longer held
-- the slot. pending_request: the newest fill offered now that covers the
-- slot and has no result for it yet. Entries are looked up by serial, store
-- and stamp range, within the slot's chunk.
--   SELECT * FROM admin.copy_holes(since => '2026-10-01');
-- contract: central/test/fills.sql
CREATE FUNCTION admin.copy_holes(since timestamp)
RETURNS TABLE (
  serial text, store store.stored_store, slot_start timestamp, slot_end timestamp,
  profile text, collector_id text, endpoint_id text, unit_id smallint, host text,
  port integer, gone boolean, pending_request uuid
)
LANGUAGE sql STABLE AS $$
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

-- As in 0024_stored_entries_checks.sql, with the optional fill results.
-- contract: central/test/schema.sql
CREATE OR REPLACE FUNCTION store.check_batch(b jsonb) RETURNS void
LANGUAGE plpgsql AS $$
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
$$;

-- As in 0025_stored_entries.sql, linking a fill request's stored entries
-- and fill results (jobs.link_fills), and counting the results.
-- contract: central/test/ingest.sql, central/test/stored.sql, central/test/requests.sql, central/test/collector_config.sql, central/test/fills.sql
CREATE OR REPLACE FUNCTION api.ingest(jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
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
       timeouts, max_ms, buckets, collector_id, batch_id)
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
  WHERE (s.buckets_version, s.retries, s.timeouts, s.max_ms, s.buckets)
        IS DISTINCT FROM (l.buckets_version, l.retries, l.timeouts, l.max_ms, l.buckets);

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
$$;

-- migrate:down
-- Forward only: undo with a new migration.
