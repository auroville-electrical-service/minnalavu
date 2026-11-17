-- migrate:up

-- health.targets finds each target's last reading and missed read per
-- target. It joined back a fleet-wide aggregate instead, and the planner,
-- estimating one target where there are hundreds, built that aggregate once
-- per target: work quadratic in targets, and again for each silent meter in
-- health.problems. The same rows, in the same columns.

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

-- Two readings indexes no health view needs, timed at 1,500 meters (9.7M
-- readings): TimescaleDB's default on the time column, which nothing reads
-- by alone; and the address one, which readings_place_time serves in its
-- place, health.endpoints taking 55 ms without it against 47 with.
DROP INDEX store.readings_read_at_idx;
DROP INDEX store.readings_address_time;

-- migrate:down
-- Forward only. Undo with a new migration.
