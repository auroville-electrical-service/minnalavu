-- Cumulative energy that went backwards: which readings store.energy_drops
-- flags, with both readings' clock signals and whether the drop is suspect;
-- which of them health.energy_drops finds from recent arrivals, and on which
-- indexes; and the problem it raises. Batches, checks and readings are
-- inserted directly, batches received relative to now().

\ir lib/assert.sql

BEGIN;

SELECT admin.set_health_thresholds(collector_silent_after => '1 hour',
  meter_silent_intervals => 4, backlog_near_capacity => 0.8, lookback => '1 day',
  endpoint_error_rate => 0.05);

INSERT INTO store.collectors (id) VALUES ('sqle_a'), ('sqle_b');

-- A profile with a register in kWh, then in Wh, one in kvarh, then in varh, and a
-- demand register.
INSERT INTO store.profile_versions (profile, version) VALUES ('sqle_test', 1), ('sqle_test', 2);
INSERT INTO store.profile_registers
  (profile, version, register_key, register_table, address, type, word_order, decimals, unit, kind)
VALUES ('sqle_test', 1, 'energy', 'holding', 0, 'u32', 'high_first', 3, 'kWh', 'cumulative'),
       ('sqle_test', 2, 'energy', 'holding', 0, 'u32', 'high_first', 0, 'Wh', 'cumulative'),
       ('sqle_test', 1, 'reactive', 'holding', 4, 'u32', 'high_first', 3, 'kvarh', 'cumulative'),
       ('sqle_test', 2, 'reactive', 'holding', 4, 'u32', 'high_first', 0, 'varh', 'cumulative'),
       ('sqle_test', 1, 'demand', 'holding', 2, 'u32', 'high_first', 0, 'kWh', 'demand');

-- Batches received `ago`: sqle_a's clock claims NTP, sqle_b's unsynced.
CREATE TEMP TABLE b (name text PRIMARY KEY, bid uuid NOT NULL);
INSERT INTO b
SELECT name, gen_random_uuid() FROM unnest(ARRAY['a_old', 'a_new', 'b_old', 'b_new']) name;
INSERT INTO store.batches
SELECT b.bid, collector, now() - ago, source,
       CASE WHEN source = 'ntp' THEN timestamptz '2026-10-31 12:00Z' END, 0, 0
FROM b
JOIN (VALUES ('a_old', 'sqle_a', '3 days'::interval, 'ntp'::store.clock_source),
             ('a_new', 'sqle_a', '5 minutes', 'ntp'),
             ('b_old', 'sqle_b', '3 days', 'unsynced'),
             ('b_new', 'sqle_b', '5 minutes', 'unsynced')) v (name, collector, ago, source)
  USING (name);

-- sqle_a's one answered check grounds its readings below; sqle_b has none.
INSERT INTO store.clock_checks
  (collector_id, t1, t4, trigger, server, outcome, t2_unix, t3_unix, address, stratum, leap,
   reference_id, batch_id)
SELECT 'sqle_a', '2026-10-31 23:00Z', '2026-10-31 23:00:00.02Z', 'daily', 'pool.ntp.org',
       'answered', 1793487600.01, 1793487600.01, '192.0.2.123', 2, 0, 3221226115, bid
FROM b WHERE name = 'a_old';

-- A reading `after` 2026-11-01 00:00Z, in batch `batch` and by its collector.
CREATE FUNCTION pg_temp.reading(serial text, register text, after interval, value numeric,
                                batch text, profile text DEFAULT 'elite_440',
                                version bigint DEFAULT 1)
RETURNS void
LANGUAGE sql AS $$
  INSERT INTO store.readings
    (meter_serial, register_key, read_at, value, profile, profile_version, endpoint_host,
     endpoint_port, unit_id, product_code, collector_id, batch_id)
  SELECT serial, register, timestamptz '2026-11-01 00:00Z' + after, value, profile, version,
         '10.0.0.1', 502, 1, 'ELITE440-445', s.collector_id, b.bid
  FROM b JOIN store.batches s ON s.batch_id = b.bid
  WHERE b.name = batch
$$;

SELECT pg_temp.reading(s, r, at, v, batch)
FROM (VALUES
  ('SQLE-DROP', 'active_energy_import', '0 minutes'::interval, 10.5, 'a_old'),
  ('SQLE-DROP', 'active_energy_import', '15 minutes', 10.4, 'a_new'),
  ('SQLE-DROP', 'active_energy_import', '30 minutes', 10.4, 'a_new'),
  ('SQLE-DROP', 'active_energy_import', '45 minutes', 10.6, 'a_new'),
  ('SQLE-DROP', 'active_energy_export', '1 minute', 0.5, 'a_old'),
  ('SQLE-DROP', 'active_energy_export', '16 minutes', 0.6, 'a_new'),
  ('SQLE-EXACT', 'active_energy_import', '0 minutes', 1.00000000000000000001, 'a_old'),
  ('SQLE-EXACT', 'active_energy_import', '15 minutes', 1.00000000000000000000, 'a_new'),
  ('SQLE-EXACT', 'active_energy_export', '0 minutes', 7, 'a_old'),
  ('SQLE-EXACT', 'active_energy_export', '15 minutes', 7.000, 'a_new'),
  ('SQLE-OLD', 'active_energy_import', '0 minutes', 5, 'a_old'),
  ('SQLE-OLD', 'active_energy_import', '15 minutes', 4, 'a_old'),
  ('SQLE-LATE', 'active_energy_import', '0 minutes', 10, 'b_old'),
  ('SQLE-LATE', 'active_energy_import', '30 minutes', 12, 'b_old'),
  ('SQLE-LATE', 'active_energy_import', '15 minutes', 13, 'b_new'),
  ('SQLE-SUSPECT', 'active_energy_import', '0 minutes', 20, 'b_old'),
  ('SQLE-SUSPECT', 'active_energy_import', '15 minutes', 19, 'b_new'),
  ('SQLE-HALF', 'active_energy_import', '0 minutes', 30, 'a_old'),
  ('SQLE-HALF', 'active_energy_import', '15 minutes', 29, 'b_new')) v (s, r, at, v, batch);

SELECT pg_temp.reading('SQLE-UNIT', 'energy', at, v, batch, 'sqle_test', version)
FROM (VALUES ('0 minutes'::interval, 1.5, 'a_old', 1::bigint),
             ('15 minutes', 1499, 'a_new', 2),
             ('30 minutes', 1.499, 'a_new', 1)) v (at, v, batch, version);
SELECT pg_temp.reading('SQLE-VARH', 'reactive', at, v, batch, 'sqle_test', version)
FROM (VALUES ('0 minutes'::interval, 2.5, 'a_old', 1::bigint),
             ('15 minutes', 2499, 'a_new', 2),
             ('30 minutes', 2.499, 'a_new', 1)) v (at, v, batch, version);
SELECT pg_temp.reading('SQLE-DEMAND', 'demand', at, v, 'a_new', 'sqle_test', 1)
FROM (VALUES ('0 minutes'::interval, 5), ('15 minutes', 3)) v (at, v);

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s %s %s %s -> %s %s', meter_serial, register_key,
                            previous_read_at - timestamptz '2026-11-01 00:00Z', previous_value,
                            previous_unit, read_at - timestamptz '2026-11-01 00:00Z', value),
                     '; ' ORDER BY meter_serial, register_key)
   FROM store.energy_drops WHERE meter_serial LIKE 'SQLE-%'),
  'SQLE-DROP active_energy_import 00:00:00 10.5 kWh -> 00:15:00 10.4; '
  || 'SQLE-EXACT active_energy_import 00:00:00 1.00000000000000000001 kWh -> 00:15:00 '
  || '1.00000000000000000000; '
  || 'SQLE-HALF active_energy_import 00:00:00 30 kWh -> 00:15:00 29; '
  || 'SQLE-LATE active_energy_import 00:15:00 13 kWh -> 00:30:00 12; '
  || 'SQLE-OLD active_energy_import 00:00:00 5 kWh -> 00:15:00 4; '
  || 'SQLE-SUSPECT active_energy_import 00:00:00 20 kWh -> 00:15:00 19; '
  || 'SQLE-UNIT energy 00:00:00 1.5 kWh -> 00:15:00 1499; '
  || 'SQLE-VARH reactive 00:00:00 2.5 kvarh -> 00:15:00 2499',
  'a cumulative reading lower than the one before it by read_at, for the same serial and '
  || 'register, is a drop, compared exactly, Wh against kWh and varh against kvarh; an equal one, another '
  || 'register''s, or a demand register''s is not');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s %s %s %s %s %s %s', meter_serial, previous_collector_id,
                            previous_clock_source, previous_clock_last_sync_at, previous_grounded,
                            collector_id, clock_source, grounded), '; ' ORDER BY meter_serial)
   FROM store.energy_drops WHERE meter_serial IN ('SQLE-DROP', 'SQLE-HALF', 'SQLE-SUSPECT')),
  'SQLE-DROP sqle_a ntp 2026-10-31 12:00:00+00 t sqle_a ntp t; '
  || 'SQLE-HALF sqle_a ntp 2026-10-31 12:00:00+00 t sqle_b unsynced f; '
  || 'SQLE-SUSPECT sqle_b unsynced  f sqle_b unsynced f',
  'each reading of a drop carries its batch''s clock claim and whether a clock check grounds it');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s', meter_serial, suspect), ', ' ORDER BY meter_serial)
   FROM store.energy_drops WHERE meter_serial LIKE 'SQLE-%'),
  'SQLE-DROP f, SQLE-EXACT f, SQLE-HALF f, SQLE-LATE t, SQLE-OLD f, SQLE-SUSPECT t, SQLE-UNIT f, '
  || 'SQLE-VARH f',
  'a drop is suspect only where no clock check grounds either reading, whatever the OS claims');

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s', serial, read_at - timestamptz '2026-11-01 00:00Z'), ', '
                     ORDER BY serial)
   FROM health.energy_drops WHERE serial LIKE 'SQLE-%'),
  'SQLE-DROP 00:15:00, SQLE-EXACT 00:15:00, SQLE-HALF 00:15:00, SQLE-LATE 00:30:00, '
  || 'SQLE-SUSPECT 00:15:00, SQLE-UNIT 00:15:00, SQLE-VARH 00:15:00',
  'the health view finds the drops at or just after a reading that arrived within the lookback, '
  || 'and not those whose readings both arrived before it');

SELECT pg_temp.is(pg_temp.unkeyed_scans('SELECT * FROM health.energy_drops'), NULL,
  'the health view reads readings only by keyed index lookups, never by a scan');

SELECT pg_temp.is(
  (SELECT detail FROM health.problems WHERE kind = 'energy_backwards' AND subject = 'SQLE-HALF'),
  'active_energy_import 29 kWh at 2026-11-01 00:15:00+00 (sqle_b, clock unsynced, unchecked) '
  || 'after 30 kWh at 2026-11-01 00:00:00+00 (sqle_a, clock ntp, checked)',
  'a drop''s problem names both readings, their collectors and clock signals');

SELECT pg_temp.is(
  (SELECT detail FROM health.problems WHERE kind = 'energy_backwards' AND subject = 'SQLE-SUSPECT'),
  'active_energy_import 19 kWh at 2026-11-01 00:15:00+00 (sqle_b, clock unsynced, unchecked) '
  || 'after 20 kWh at 2026-11-01 00:00:00+00 (sqle_b, clock unsynced, unchecked), '
  || 'suspect: no clock check grounds either',
  'and says when it is suspect');

SELECT pg_temp.is(
  (SELECT string_agg(subject, ', ' ORDER BY subject) FROM health.problems
   WHERE kind = 'energy_backwards'),
  'SQLE-DROP, SQLE-EXACT, SQLE-HALF, SQLE-LATE, SQLE-SUSPECT, SQLE-UNIT, SQLE-VARH',
  'each serial with a drop found by the health view is one problem');

SELECT admin.set_health_thresholds(collector_silent_after => '1 hour',
  meter_silent_intervals => 4, backlog_near_capacity => 0.8, lookback => '4 days',
  endpoint_error_rate => 0.05);

SELECT pg_temp.ok(
  (SELECT 'SQLE-OLD' IN (SELECT subject FROM health.problems WHERE kind = 'energy_backwards')),
  'a drop is judged by the lookback in force');

-- A register reaching its largest value and wrapping to a small one: the
-- 440's energy registers are f32, the 500's f64, and neither profile names a
-- rollover, so the largest finite float stands for the top.
SELECT pg_temp.reading('SQLW-440', 'active_energy_import', at, v, batch)
FROM (VALUES ('0 minutes'::interval, 340282350000000000000000000000000000000, 'a_old'),
             ('15 minutes', 0.5, 'a_new')) v (at, v, batch);
SELECT pg_temp.reading('SQLW-500', 'active_energy_import', at, v::numeric, batch, 'elite_500')
FROM (VALUES ('0 minutes'::interval, '17976931348623157' || repeat('0', 292), 'a_old'),
             ('15 minutes', '0.5', 'a_new')) v (at, v, batch);

SELECT pg_temp.is(
  (SELECT string_agg(format('%s %s -> %s %s', meter_serial, length(previous_value::text), value,
                            suspect), '; ' ORDER BY meter_serial)
   FROM store.energy_drops WHERE meter_serial LIKE 'SQLW-%'),
  'SQLW-440 39 -> 0.5 f; SQLW-500 309 -> 0.5 f',
  'a register wrapping from its largest value to a small one is a drop, reported like a reset: '
  || 'the views cannot tell a wrap from a reset, a swap or a write');

SELECT pg_temp.is(
  (SELECT detail FROM health.problems WHERE kind = 'energy_backwards' AND subject = 'SQLW-440'),
  'active_energy_import 0.5 kWh at 2026-11-01 00:15:00+00 (sqle_a, clock ntp, checked) '
  || 'after 340282350000000000000000000000000000000 kWh at 2026-11-01 00:00:00+00 '
  || '(sqle_a, clock ntp, checked)',
  'and raises energy_backwards with both values exact, as for any drop');

ROLLBACK;
