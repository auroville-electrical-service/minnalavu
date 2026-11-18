-- migrate:up

-- Diagnostics of meters' clocks and of copying: each meter-clock read's
-- offset from true time, grounded through its collector's clock checks; the
-- steps between consecutive reads of one meter; a meter whose clock is far
-- from the others on its collector; and a copied meter whose copies fail
-- while it is polled less often than a meter without copies must be.

-- The first values of these three are guesses, to be set from the pilot.
ALTER TABLE registry.health_thresholds
  -- A meter's offset moving more than this between two reads is a step: a
  -- clock set or stopped, not drift (seconds a day).
  ADD COLUMN meter_clock_step_after interval NOT NULL DEFAULT interval '5 minutes'
    CHECK (meter_clock_step_after > interval '0'),
  -- A meter's offset this far from the median of its collector's meters.
  -- Meters on one collector share a time zone, so the zone cancels.
  ADD COLUMN meter_clock_far_after interval NOT NULL DEFAULT interval '15 minutes'
    CHECK (meter_clock_far_after > interval '0'),
  -- A copied meter whose copies fail is polled at least this often.
  ADD COLUMN copy_failing_interval interval NOT NULL DEFAULT interval '30 minutes'
    CHECK (copy_failing_interval > interval '0');
ALTER TABLE registry.health_thresholds
  ALTER COLUMN meter_clock_step_after DROP DEFAULT,
  ALTER COLUMN meter_clock_far_after DROP DEFAULT,
  ALTER COLUMN copy_failing_interval DROP DEFAULT;

DROP FUNCTION admin.set_health_thresholds(
  interval, numeric, numeric, interval, numeric, interval, interval, interval, interval, interval);
CREATE FUNCTION admin.set_health_thresholds(
  collector_silent_after interval, meter_silent_intervals numeric,
  backlog_near_capacity numeric, lookback interval, endpoint_error_rate numeric,
  snapshot_missed_margin interval, history_behind_after interval,
  snapshot_behind_after_elite_500 interval, load_survey_behind_after_elite_440 interval,
  load_survey_behind_after_elite_500 interval, meter_clock_step_after interval,
  meter_clock_far_after interval, copy_failing_interval interval
) RETURNS bigint
LANGUAGE sql AS $$
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

CREATE OR REPLACE VIEW health.thresholds AS
  SELECT collector_silent_after, meter_silent_intervals, backlog_near_capacity, lookback, set_at,
         endpoint_error_rate, snapshot_missed_margin, history_behind_after,
         snapshot_behind_after_elite_500, load_survey_behind_after_elite_440,
         load_survey_behind_after_elite_500, meter_clock_step_after, meter_clock_far_after,
         copy_failing_interval
  FROM registry.health_thresholds
  ORDER BY version_id DESC
  LIMIT 1;

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

-- Per grounded meter-clock read that arrived within the lookback, its step
-- from the meter's previous grounded read (by serial, wherever it was read)
-- when that moved more than meter_clock_step_after: the clock was set or
-- stopped between the two reads. Found by arrival, so a weeks-late batch's
-- steps are listed when it comes.
-- contract: central/test/health.sql
CREATE VIEW health.meter_clock_steps AS
  WITH t AS (SELECT * FROM health.thresholds)
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

-- Per target in service now on an endpoint in service, the last grounded
-- meter-clock read at its address: the meter's offset, and its distance from
-- the median offset of its collector's meters. Far when that passes
-- meter_clock_far_after and the collector has at least three such meters:
-- the median of two is one of the two it would judge. Endpoints and targets'
-- reads are each found once: inlined, the planner rebuilt the endpoints for
-- every target and the medians for every meter, work quadratic in meters.
-- contract: central/test/health.sql
CREATE VIEW health.meter_clocks AS
  WITH t AS (SELECT * FROM health.thresholds),
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

-- Per copied target whose meter is known: the stores health.copy_stores
-- finds behind, the snapshot days health.missed_snapshots finds missed, and
-- how often it is polled. Polled slowly when its copies fail and it is
-- polled less often than copy_failing_interval.
-- contract: central/test/health.sql
CREATE VIEW health.copy_meters AS
  WITH t AS (SELECT * FROM health.thresholds),
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

-- One row per problem, as in 0030_problems_once.sql, with meter_clock_step,
-- meter_clock_far and copy_failing_polled_slowly.
-- contract: central/test/health.sql, central/test/collector_config.sql
CREATE OR REPLACE VIEW health.problems AS
  WITH collectors AS MATERIALIZED (SELECT * FROM health.collectors),
  targets AS MATERIALIZED (SELECT * FROM health.targets)
  SELECT 'collector_silent' AS kind, c.collector_id AS subject,
         format('no upload since %s (%s endpoints in service)',
                coalesce(c.last_upload_at::text, 'it was registered'), c.endpoints) AS detail
  FROM collectors c WHERE c.silent
  UNION ALL
  SELECT 'backlog_near_capacity', c.collector_id,
         format('backlog %s of %s bytes (%s%%), oldest %s', c.backlog_bytes, c.backlog_max_bytes,
                round(c.backlog_used * 100, 1), c.backlog_oldest)
  FROM collectors c WHERE c.backlog_near_capacity
  UNION ALL
  SELECT 'backlog_refused', c.collector_id,
         format('%s events refused since the collector started', c.backlog_refused)
  FROM collectors c WHERE c.has_refused
  UNION ALL
  SELECT 'backlog_discarded', c.collector_id,
         format('%s .discarded files in the buffer', c.backlog_discarded_files)
  FROM collectors c WHERE c.has_discarded
  UNION ALL
  SELECT 'backlog_quarantined', c.collector_id,
         format('%s batches in quarantine', c.backlog_quarantined)
  FROM collectors c WHERE c.has_quarantined
  UNION ALL
  SELECT 'config_refused', c.collector_id,
         format('refused the served config %s (%s); still applying %s', c.config_refused_digest,
                regexp_replace(c.config_refusal_reason, '[[:cntrl:]]', '?', 'g'), c.config_digest)
  FROM collectors c WHERE c.has_config_refused
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
  SELECT 'target_silent', format('%s unit %s', g.endpoint_id, g.unit_id),
         format('no reading since %s (expected every %s; %s), at %s:%s unit %s '
                || 'via %s, profile %s, %s',
                coalesce(g.last_reading_at::text, 'it came into service'), g.expected_interval,
                coalesce('last missed read ' || g.last_missed_read_at, 'no missed read'),
                g.host, g.port, g.unit_id, g.collector_id, g.profile,
                coalesce('meter ' || g.serial, 'no meter placed'))
  FROM targets g
  JOIN collectors c USING (collector_id)
  WHERE g.silent AND NOT c.silent
  UNION ALL
  SELECT 'meter_silent', m.serial,
         format('no reading since %s (expected every %s), on %s unit %s, collector %s',
                coalesce(m.last_reading_at::text, 'it came into service'), m.expected_interval,
                m.endpoint_id, m.unit_id, m.collector_id)
  FROM health.meters m
  JOIN collectors c USING (collector_id)
  JOIN targets g USING (endpoint_id, unit_id)
  WHERE m.silent AND NOT c.silent AND NOT g.silent
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
  GROUP BY e.serial
  UNION ALL
  SELECT 'snapshot_missed', m.serial,
         format('no snapshot copied for meter day %s, now replaced on the meter; its clock read '
                || '%s from UTC at %s; at %s:%s unit %s via %s',
                string_agg(m.meter_day::text, ', ' ORDER BY m.meter_day), m.meter_offset,
                m.clock_read_at, m.host, m.port, m.unit_id, m.collector_id)
  FROM health.missed_snapshots m
  GROUP BY m.serial, m.meter_offset, m.clock_read_at, m.host, m.port, m.unit_id, m.collector_id
  UNION ALL
  SELECT 'copy_behind', format('%s %s', s.serial, s.store),
         format('newest %s entry copied %s, more than %s before the meter''s clock at the last '
                || 'upload (%s); at %s:%s unit %s via %s, profile %s',
                s.store, coalesce(s.newest_entry::text, 'none'), s.behind_after,
                s.meter_at_upload, s.host, s.port, s.unit_id, s.collector_id, s.profile)
  FROM health.copy_stores s
  WHERE s.behind
  UNION ALL
  SELECT 'meter_clock_step', s.serial,
         string_agg(format('clock moved %s between %s and %s (%s to %s from UTC), at %s:%s unit %s '
                           || 'via %s',
                           s.step, s.previous_read_at, s.read_at, s.previous_meter_offset,
                           s.meter_offset, s.host, s.port, s.unit_id, s.collector_id),
                    '; ' ORDER BY s.read_at)
  FROM health.meter_clock_steps s
  GROUP BY s.serial
  UNION ALL
  SELECT 'meter_clock_far', k.serial,
         format('clock %s from UTC at %s, %s from the median of the %s meters on %s; '
                || 'at %s:%s unit %s',
                k.meter_offset, k.read_at, k.from_median, k.collector_meters, k.collector_id,
                k.host, k.port, k.unit_id)
  FROM health.meter_clocks k
  WHERE k.far
  UNION ALL
  SELECT 'copy_failing_polled_slowly', m.serial,
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

GRANT SELECT ON health.meter_clock_offsets, health.meter_clock_steps, health.meter_clocks,
  health.copy_meters TO monitor;

-- migrate:down
-- Forward only. Undo with a new migration.
