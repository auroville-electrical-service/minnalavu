-- Copy holes, for a session's judgement (ADR 0025; skills/minnalavu-ops/copy-holes.md).
-- Read only. Slots and ranges are meter-clock times, as admin.copy_holes
-- gives them.
--   bin/dev central sh -c 'psql "$MINNALAVU_DB_URL" -X -v since=2026-10-01 -f ../skills/minnalavu-ops/holes.sql'
\pset pager off

\echo '== 1. holes per meter and store'
SELECT collector_id, serial, store, count(*) AS slots,
       min(slot_start) AS first, max(slot_end) AS last,
       count(*) FILTER (WHERE gone) AS gone,
       count(*) FILTER (WHERE pending_request IS NOT NULL) AS pending
FROM admin.copy_holes(since => :'since')
GROUP BY collector_id, serial, store
ORDER BY collector_id, serial, store;

\echo '== 2. holes a finished fill covered whole, not gone: the meter did not hold them'
SELECT h.serial, h.store, h.slot_start, r.request_id, r.finished_at
FROM admin.copy_holes(since => :'since') h
JOIN jobs.request_fill_results r ON (r.meter_serial, r.store) = (h.serial, h.store)
JOIN jobs.request_fills f ON f.request_id = r.request_id
WHERE NOT h.gone AND f.from_time <= h.slot_start AND f.to_time >= h.slot_end
ORDER BY h.serial, h.store, h.slot_start;

\echo '== 3. open holes: not gone, not pending, not already answered'
SELECT h.collector_id, h.serial, h.store, min(h.slot_start) AS from_time,
       max(h.slot_end) AS to_time, count(*) AS slots
FROM admin.copy_holes(since => :'since') h
WHERE NOT h.gone AND h.pending_request IS NULL
  AND NOT EXISTS (
    SELECT FROM jobs.request_fill_results r
    JOIN jobs.request_fills f ON f.request_id = r.request_id
    WHERE (r.meter_serial, r.store) = (h.serial, h.store)
      AND f.from_time <= h.slot_start AND f.to_time >= h.slot_end)
GROUP BY h.collector_id, h.serial, h.store
ORDER BY h.collector_id, h.serial, h.store;

\echo '== 4. uploads reporting buffer segments discarded or quarantined since the one before'
SELECT collector_id, received_at, backlog_discarded_files, backlog_quarantined
FROM (SELECT u.*,
             lag(u.backlog_discarded_files) OVER w AS discarded_before,
             lag(u.backlog_quarantined) OVER w AS quarantined_before
      FROM store.uploads u
      WINDOW w AS (PARTITION BY u.collector_id ORDER BY u.received_at)) u
WHERE u.backlog_discarded_files > u.discarded_before
   OR u.backlog_quarantined > u.quarantined_before
ORDER BY collector_id, received_at;

\echo '== 5. meter clock steps'
SELECT serial, collector_id, read_at, previous_meter_offset, meter_offset, step
FROM health.meter_clock_steps
ORDER BY serial, read_at;

\echo '== 6. fills, newest first'
SELECT request_id, collector_id, state, meters, requested_at, expires_at, stored_entries,
       fill_results
FROM jobs.request_status
WHERE kind::text = 'fill_copies'
ORDER BY requested_at DESC
LIMIT 20;
