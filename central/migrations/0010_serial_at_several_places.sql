-- migrate:up

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

-- One row per problem: (kind, subject) names it, detail describes it now.
-- contract: central/test/health.sql
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
  HAVING count(*) > 1;

GRANT SELECT ON health.unregistered_serial_places TO monitor;

-- migrate:down
-- Forward only. Undo with a new migration.
