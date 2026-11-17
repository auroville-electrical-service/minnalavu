-- migrate:up

-- health.problems computes health.collectors and health.targets once each.
-- Inlined, the planner joined them back per row: collectors once for every
-- silent target, targets once for every silent meter. So the view cost most
-- when a collector was offline and its targets all silent, which is when the
-- alert most needs it. The same rows, as in 0027_copy_health.sql.

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
  WHERE s.behind;

-- migrate:down
-- Forward only. Undo with a new migration.
