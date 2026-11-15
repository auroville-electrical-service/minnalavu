-- migrate:up

-- Per-endpoint health: how many of the reads due at each endpoint within the
-- lookback were taken and how many missed, by reason. The store holds no
-- request latency, so none is shown.

-- An endpoint whose reads failed at this share or more is erroring. The
-- first value is a guess, to be set from the pilot's figures.
ALTER TABLE registry.health_thresholds
  ADD COLUMN endpoint_error_rate numeric NOT NULL DEFAULT 0.05
    CHECK (endpoint_error_rate > 0 AND endpoint_error_rate <= 1);
ALTER TABLE registry.health_thresholds ALTER COLUMN endpoint_error_rate DROP DEFAULT;

DROP FUNCTION admin.set_health_thresholds(interval, numeric, numeric, interval);
CREATE FUNCTION admin.set_health_thresholds(
  collector_silent_after interval, meter_silent_intervals numeric,
  backlog_near_capacity numeric, lookback interval, endpoint_error_rate numeric
) RETURNS bigint
LANGUAGE sql AS $$
  INSERT INTO registry.health_thresholds
    (collector_silent_after, meter_silent_intervals, backlog_near_capacity, lookback,
     endpoint_error_rate)
  VALUES (collector_silent_after, meter_silent_intervals, backlog_near_capacity, lookback,
          endpoint_error_rate)
  RETURNING version_id
$$;

CREATE OR REPLACE VIEW health.thresholds AS
  SELECT collector_silent_after, meter_silent_intervals, backlog_near_capacity, lookback, set_at,
         endpoint_error_rate
  FROM registry.health_thresholds
  ORDER BY version_id DESC
  LIMIT 1;

-- For an endpoint's readings and missed reads by address and time.
CREATE INDEX readings_address_time
  ON store.readings (collector_id, endpoint_host, endpoint_port, read_at);
CREATE INDEX missed_reads_address_time
  ON store.missed_reads (collector_id, endpoint_host, endpoint_port, read_at);

-- Per registered endpoint, as registered now: the reads due at it within the
-- lookback, counted at each address it had while in service, from when it
-- had it. A read is a register: a reading, or a missed read. failed_reads
-- leaves out decode and profile_mismatch, which are the meter's answer, not
-- the read failing; error_rate is failed_reads over every read due, NULL when
-- none was. erroring: in service, read by us, and error_rate at or above
-- endpoint_error_rate.
-- contract: central/test/endpoints.sql
CREATE VIEW health.endpoints AS
  WITH t AS (SELECT * FROM health.thresholds),
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

-- One row per problem: (kind, subject) names it, detail describes it now.
-- contract: central/test/health.sql, central/test/clock.sql, central/test/energy.sql,
--   central/test/endpoints.sql
CREATE OR REPLACE VIEW health.problems AS
  SELECT 'collector_silent' AS kind, c.collector_id AS subject,
         format('no upload since %s (%s endpoints in service)',
                coalesce(c.last_upload_at::text, 'it was registered'), c.endpoints) AS detail
  FROM health.collectors c WHERE c.silent
  UNION ALL
  SELECT 'backlog_near_capacity', c.collector_id,
         format('backlog %s of %s bytes (%s%%), oldest %s', c.backlog_bytes, c.backlog_max_bytes,
                round(c.backlog_used * 100, 1), c.backlog_oldest)
  FROM health.collectors c WHERE c.backlog_near_capacity
  UNION ALL
  SELECT 'backlog_refused', c.collector_id,
         format('%s events refused since the collector started', c.backlog_refused)
  FROM health.collectors c WHERE c.has_refused
  UNION ALL
  SELECT 'backlog_discarded', c.collector_id,
         format('%s .discarded files in the buffer', c.backlog_discarded_files)
  FROM health.collectors c WHERE c.has_discarded
  UNION ALL
  SELECT 'backlog_quarantined', c.collector_id,
         format('%s batches in quarantine', c.backlog_quarantined)
  FROM health.collectors c WHERE c.has_quarantined
  UNION ALL
  SELECT 'clock_unchecked', k.collector_id,
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
  SELECT 'meter_silent', m.serial,
         format('no reading since %s (expected every %s), on %s unit %s, collector %s',
                coalesce(m.last_reading_at::text, 'it came into service'), m.expected_interval,
                m.endpoint_id, m.unit_id, m.collector_id)
  FROM health.meters m
  JOIN health.collectors c USING (collector_id)
  WHERE m.silent AND NOT c.silent
  UNION ALL
  SELECT 'endpoint_errors', e.endpoint_id,
         format('%s of %s reads failed (%s%%) within %s, missed by reason %s, at %s:%s via %s',
                e.failed_reads, e.readings + e.missed_reads, round(e.error_rate * 100, 2),
                t.lookback, e.missed_by_reason, e.host, e.port, e.collector_id)
  FROM health.endpoints e
  CROSS JOIN health.thresholds t
  WHERE e.erroring
  UNION ALL
  SELECT 'unregistered_serial', u.serial,
         format('%s readings, the last at %s, from %s', u.readings, u.last_reading_at,
                array_to_string(u.collectors, ', '))
  FROM health.unregistered_serials u
  UNION ALL
  SELECT 'misplaced_serial', p.serial,
         string_agg(format('%s readings, the last at %s, at %s:%s unit %s via %s (registered at %s)',
                           p.readings, p.last_reading_at, p.endpoint_host, p.endpoint_port,
                           p.unit_id, p.collector_id, array_to_string(p.registered_at, ', ')),
                    '; ' ORDER BY p.collector_id, p.endpoint_host, p.endpoint_port, p.unit_id)
  FROM health.misplaced_serials p
  GROUP BY p.serial
  UNION ALL
  SELECT 'serial_at_several_places', u.serial,
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
         string_agg(format('%s: %s readings, from %s to %s', s.serial, s.readings,
                           s.first_reading_at, s.last_reading_at),
                    '; ' ORDER BY s.first_reading_at, s.serial)
  FROM health.place_serials s
  GROUP BY s.collector_id, s.endpoint_host, s.endpoint_port, s.unit_id
  UNION ALL
  SELECT 'firmware_changed', f.serial,
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
  SELECT 'energy_backwards', e.serial,
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
  GROUP BY e.serial;

GRANT SELECT ON health.endpoints TO monitor;

-- migrate:down
-- Forward only. Undo with a new migration.
