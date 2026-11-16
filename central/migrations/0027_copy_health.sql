-- migrate:up

-- Two problems with copying meters' stored entries: a 440's daily snapshot
-- night not copied before the meter replaced it, and a store whose newest
-- copied entry is old enough that the entries after it near the end of what
-- the meter keeps. Both judge a meter by its own clock, as its last
-- meter-clock read places it beside the collector's.

-- The first values of these five are guesses, to be set from the copies the
-- pilot makes. How long each store is kept is the meter's own (its count
-- registers), not the profile's, so each behind_after is chosen below what
-- the pilot's meters of that model were found to keep.
ALTER TABLE registry.health_thresholds
  -- How long after a 440 replaced a day's snapshot, by its clock, before the
  -- day counts as missed: covers drift since the clock read and upload lag.
  ADD COLUMN snapshot_missed_margin interval NOT NULL DEFAULT interval '1 hour'
    CHECK (snapshot_missed_margin > interval '0'),
  -- A store is behind when its newest copied entry is older than this, by
  -- the meter's clock. Histories are monthly and both models keep six.
  ADD COLUMN history_behind_after interval NOT NULL DEFAULT interval '62 days'
    CHECK (history_behind_after > interval '0'),
  ADD COLUMN snapshot_behind_after_elite_500 interval NOT NULL DEFAULT interval '14 days'
    CHECK (snapshot_behind_after_elite_500 > interval '0'),
  ADD COLUMN load_survey_behind_after_elite_440 interval NOT NULL DEFAULT interval '7 days'
    CHECK (load_survey_behind_after_elite_440 > interval '0'),
  ADD COLUMN load_survey_behind_after_elite_500 interval NOT NULL DEFAULT interval '30 days'
    CHECK (load_survey_behind_after_elite_500 > interval '0');
ALTER TABLE registry.health_thresholds
  ALTER COLUMN snapshot_missed_margin DROP DEFAULT,
  ALTER COLUMN history_behind_after DROP DEFAULT,
  ALTER COLUMN snapshot_behind_after_elite_500 DROP DEFAULT,
  ALTER COLUMN load_survey_behind_after_elite_440 DROP DEFAULT,
  ALTER COLUMN load_survey_behind_after_elite_500 DROP DEFAULT;

DROP FUNCTION admin.set_health_thresholds(interval, numeric, numeric, interval, numeric);
CREATE FUNCTION admin.set_health_thresholds(
  collector_silent_after interval, meter_silent_intervals numeric,
  backlog_near_capacity numeric, lookback interval, endpoint_error_rate numeric,
  snapshot_missed_margin interval, history_behind_after interval,
  snapshot_behind_after_elite_500 interval, load_survey_behind_after_elite_440 interval,
  load_survey_behind_after_elite_500 interval
) RETURNS bigint
LANGUAGE sql AS $$
  INSERT INTO registry.health_thresholds
    (collector_silent_after, meter_silent_intervals, backlog_near_capacity, lookback,
     endpoint_error_rate, snapshot_missed_margin, history_behind_after,
     snapshot_behind_after_elite_500, load_survey_behind_after_elite_440,
     load_survey_behind_after_elite_500)
  VALUES (collector_silent_after, meter_silent_intervals, backlog_near_capacity, lookback,
          endpoint_error_rate, snapshot_missed_margin, history_behind_after,
          snapshot_behind_after_elite_500, load_survey_behind_after_elite_440,
          load_survey_behind_after_elite_500)
  RETURNING version_id
$$;

CREATE OR REPLACE VIEW health.thresholds AS
  SELECT collector_silent_after, meter_silent_intervals, backlog_near_capacity, lookback, set_at,
         endpoint_error_rate, snapshot_missed_margin, history_behind_after,
         snapshot_behind_after_elite_500, load_survey_behind_after_elite_440,
         load_survey_behind_after_elite_500
  FROM registry.health_thresholds
  ORDER BY version_id DESC
  LIMIT 1;

-- Per registered target copied now (it and its endpoint in service, copy
-- on, no other system polling it), as registered now: since when its
-- endpoint has copied without a break; the meter its last meter-clock read
-- at the unit's address found, NULL until one comes; when that serial's
-- clock was first read anywhere, which is when a collector able to copy
-- first saw it; the meter's offset from UTC as that read measured it, its
-- zone and drift together; and its collector's last upload. Each a keyed
-- lookup: the place and serial keys of store.meter_clock_reads, the
-- collector key of store.uploads.
-- contract: central/test/health.sql
CREATE VIEW health.copy_targets AS
  SELECT g.endpoint_id, g.unit_id, e.collector_id, e.host, e.port, g.profile,
         c.meter_serial AS serial,
         coalesce(
           (SELECT max(upper(x.period)) FROM registry.endpoint_history x
            WHERE x.endpoint_id = g.endpoint_id
              AND NOT (x.in_service AND x.copy AND NOT x.polled_by_other_system)
              AND upper(x.period) <= now()),
           (SELECT min(x.valid_from) FROM registry.endpoint_versions x
            WHERE x.endpoint_id = g.endpoint_id)) AS copying_since,
         (SELECT min(f.collector_at) FROM store.meter_clock_reads f
          WHERE f.meter_serial = c.meter_serial) AS first_seen_at,
         c.collector_at AS clock_read_at,
         c.meter_time - (c.collector_at AT TIME ZONE 'UTC') AS meter_offset,
         (SELECT max(u.received_at) FROM store.uploads u WHERE u.collector_id = e.collector_id)
           AS last_upload_at
  FROM registry.target_history g
  JOIN registry.endpoint_history e ON e.endpoint_id = g.endpoint_id AND e.period @> now()
  LEFT JOIN LATERAL (
    SELECT m.meter_serial, m.collector_at, m.meter_time FROM store.meter_clock_reads m
    WHERE (m.collector_id, m.endpoint_host, m.endpoint_port, m.unit_id)
          = (e.collector_id, e.host, e.port, g.unit_id)
    ORDER BY m.collector_at DESC
    LIMIT 1
  ) c ON true
  WHERE g.period @> now() AND g.in_service AND e.in_service AND e.copy
    AND NOT e.polled_by_other_system;

-- A 440 keeps one daily snapshot, stamped at its midnight and replaced at
-- the next, so a day whose snapshot was not copied is lost. Per copied 440
-- whose meter is known, each meter day missed: its snapshot taken (by the
-- meter's clock) after its endpoint began copying and the meter was first
-- seen; replaced at least snapshot_missed_margin before the collector's last
-- upload, as the meter's clock then read, so that upload could have carried
-- it; replaced within the lookback, so a missed day is listed for that long;
-- and no snapshot entry of the serial stamped that day. Clock reads and
-- uploads are taken from health.copy_targets; the entries are looked up by
-- serial, store and stamp range, within the day's chunk.
-- contract: central/test/health.sql
CREATE VIEW health.missed_snapshots AS
  WITH t AS (SELECT * FROM health.thresholds),
  k AS (
    SELECT k.*,
           (now() AT TIME ZONE 'UTC') + k.meter_offset AS meter_now,
           (k.last_upload_at AT TIME ZONE 'UTC') + k.meter_offset AS meter_at_upload,
           (greatest(k.copying_since, k.first_seen_at) AT TIME ZONE 'UTC') + k.meter_offset
             AS meter_since
    FROM health.copy_targets k
    WHERE k.profile = 'elite_440' AND k.serial IS NOT NULL
  )
  SELECT k.serial, k.endpoint_id, k.unit_id, k.collector_id, k.host, k.port,
         d::date AS meter_day, k.meter_offset, k.clock_read_at
  FROM k
  CROSS JOIN t
  CROSS JOIN LATERAL generate_series(
    date_trunc('day', k.meter_now - t.snapshot_missed_margin - t.lookback),
    k.meter_at_upload - t.snapshot_missed_margin - interval '1 day',
    interval '1 day') d
  -- LIMIT keeps this a lookup per day: as NOT EXISTS, the planner may join
  -- it against every snapshot entry instead.
  LEFT JOIN LATERAL (
    SELECT true AS copied FROM store.stored_entries s
    WHERE s.meter_serial = k.serial AND s.store = 'snapshot'
      AND s.meter_time >= d AND s.meter_time < d + interval '1 day'
    LIMIT 1
  ) s ON true
  WHERE d >= k.meter_since
    AND d + interval '1 day' > k.meter_now - t.snapshot_missed_margin - t.lookback
    AND s.copied IS NULL;

-- Per copied target whose meter is known, and per store its profile copies
-- with a behind_after: the store is behind when no entry of the serial is
-- stamped later than behind_after before the meter's clock at the
-- collector's last upload, and the endpoint copied and the meter was seen
-- since before then. A 440's snapshot is judged in health.missed_snapshots
-- instead; a profile not listed here is not judged. behind is an existence
-- test by serial, store and stamp range over the chunks that range reaches;
-- newest_entry walks each of the profile's register keys for that store, by
-- key, from the newest.
-- contract: central/test/health.sql
CREATE VIEW health.copy_stores AS
  WITH t AS (SELECT * FROM health.thresholds),
  k AS (
    SELECT k.*,
           (k.last_upload_at AT TIME ZONE 'UTC') + k.meter_offset AS meter_at_upload,
           (greatest(k.copying_since, k.first_seen_at) AT TIME ZONE 'UTC') + k.meter_offset
             AS meter_since
    FROM health.copy_targets k
    WHERE k.serial IS NOT NULL
  )
  SELECT k.serial, s.store, k.endpoint_id, k.unit_id, k.collector_id, k.host, k.port, k.profile,
         s.behind_after,
         (SELECT max(n.meter_time)
          FROM (SELECT DISTINCT p.register_key FROM store.profile_stored p
                WHERE p.profile = k.profile AND p.store = s.store) r
          CROSS JOIN LATERAL (
            SELECT e.meter_time FROM store.stored_entries e
            WHERE (e.meter_serial, e.store, e.register_key) = (k.serial, s.store, r.register_key)
            ORDER BY e.meter_time DESC
            LIMIT 1
          ) n) AS newest_entry,
         k.meter_at_upload,
         coalesce(k.meter_since < k.meter_at_upload - s.behind_after
                  AND NOT EXISTS (
                    SELECT FROM store.stored_entries e
                    WHERE e.meter_serial = k.serial AND e.store = s.store
                      AND e.meter_time >= k.meter_at_upload - s.behind_after),
                  false) AS behind
  FROM k
  CROSS JOIN t
  CROSS JOIN LATERAL (
    VALUES ('elite_440', 'history'::store.stored_store, t.history_behind_after),
           ('elite_440', 'load_survey', t.load_survey_behind_after_elite_440),
           ('elite_500', 'history', t.history_behind_after),
           ('elite_500', 'snapshot', t.snapshot_behind_after_elite_500),
           ('elite_500', 'load_survey', t.load_survey_behind_after_elite_500)
  ) s (profile, store, behind_after)
  WHERE s.profile = k.profile;

-- One row per problem, as in 0022_target_silent_on_readings.sql, with
-- snapshot_missed and copy_behind.
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

GRANT SELECT ON health.copy_targets, health.missed_snapshots, health.copy_stores TO monitor;

-- migrate:down
-- Forward only. Undo with a new migration.
