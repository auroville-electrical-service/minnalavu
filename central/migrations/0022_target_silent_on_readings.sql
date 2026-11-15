-- migrate:up

-- A target is silent when no reading came at its unit for
-- meter_silent_intervals × its interval: a missed read is not a reading, so
-- a unit that times out every round is silent. Its last missed read stays in
-- the view, and in the problem's detail, for diagnosis.

-- contract: central/test/health.sql
CREATE OR REPLACE VIEW health.targets AS
  WITH t AS (SELECT * FROM health.thresholds),
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
  ),
  last AS (
    SELECT g.endpoint_id, g.unit_id, max(r.read_at) AS reading_at, max(x.read_at) AS missed_at
    FROM g
    JOIN registry.endpoint_history a ON a.endpoint_id = g.endpoint_id AND a.in_service
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
    GROUP BY g.endpoint_id, g.unit_id
  )
  SELECT g.endpoint_id, g.unit_id, g.in_service, g.collector_id, g.host, g.port, g.profile,
         g.serial, g.polled_by_other_system, g.expected, g.expected_interval, g.in_service_since,
         l.reading_at AS last_reading_at, l.missed_at AS last_missed_read_at,
         g.expected
           AND greatest(l.reading_at, g.in_service_since)
               < now() - t.meter_silent_intervals * g.expected_interval AS silent
  FROM g
  CROSS JOIN t
  LEFT JOIN last l USING (endpoint_id, unit_id);

-- contract: central/test/health.sql, central/test/collector_config.sql
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
  SELECT 'config_refused', c.collector_id,
         format('refused the served config %s (%s); still applying %s', c.config_refused_digest,
                regexp_replace(c.config_refusal_reason, '[[:cntrl:]]', '?', 'g'), c.config_digest)
  FROM health.collectors c WHERE c.has_config_refused
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
  FROM health.targets g
  JOIN health.collectors c USING (collector_id)
  WHERE g.silent AND NOT c.silent
  UNION ALL
  SELECT 'meter_silent', m.serial,
         format('no reading since %s (expected every %s), on %s unit %s, collector %s',
                coalesce(m.last_reading_at::text, 'it came into service'), m.expected_interval,
                m.endpoint_id, m.unit_id, m.collector_id)
  FROM health.meters m
  JOIN health.collectors c USING (collector_id)
  JOIN health.targets g USING (endpoint_id, unit_id)
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
  GROUP BY e.serial;

-- migrate:down
-- Forward only. Undo with a new migration.
