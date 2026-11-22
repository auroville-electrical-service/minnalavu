-- migrate:up

-- An endpoint that takes each connection and closes it before sending a byte
-- (a gateway whose one connection another client holds) is its own problem,
-- endpoint_closes_connections, in place of the endpoint_silent,
-- endpoint_never_read or endpoint_errors it would otherwise raise: its last
-- missed read within the lookback is unreachable with detail closed, and no
-- unit of it has been read since. Other kinds are as in 0037_problem_keys.sql.

DROP VIEW health.problems;

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

GRANT SELECT ON health.problems TO monitor;

-- migrate:down
-- Forward only. Undo with a new migration.
