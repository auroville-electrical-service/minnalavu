-- migrate:up

-- Cumulative energy that went backwards: a reading lower than the one before
-- it for the same serial and register, by read_at. An energy or factory
-- reset, a swap, a write, or the collector's clock stepping back; the views
-- report the drop and both readings' clock signals, and judge no bill.

-- For readings by the batch that brought them, and batches by arrival.
CREATE INDEX ON store.readings (batch_id);
CREATE INDEX ON store.batches (received_at);

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

-- One row per problem: (kind, subject) names it, detail describes it now.
-- contract: central/test/health.sql, central/test/clock.sql, central/test/energy.sql
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

GRANT SELECT ON health.energy_drops TO monitor;

-- migrate:down
-- Forward only. Undo with a new migration.
