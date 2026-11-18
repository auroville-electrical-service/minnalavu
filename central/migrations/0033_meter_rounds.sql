-- migrate:up

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

GRANT SELECT ON health.meter_rounds TO monitor;

-- migrate:down
-- Forward only. Undo with a new migration.
