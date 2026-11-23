-- The key columns of the one problem of a kind and subject, as
-- collector/endpoint/host:port/unit/serial with - for NULL, for comparing
-- with a written-out value. Every test of a kind's key columns comes
-- through here, so here each kind a test raises is checked against
-- health.problem_kinds: it has a row, and its subject names what its level
-- says. Either failing stops the file.

CREATE FUNCTION pg_temp.keys(want_kind text, want_subject text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
  p health.problems;
  level text;
BEGIN
  SELECT * INTO p FROM health.problems WHERE kind = want_kind AND subject = want_subject;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  SELECT k.level INTO level FROM health.problem_kinds k WHERE k.kind = p.kind;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'not ok - kind % has no row in health.problem_kinds', p.kind;
  END IF;
  IF p.subject IS DISTINCT FROM pg_temp.subject_at(level, p) THEN
    RAISE EXCEPTION 'not ok - % subject % does not name its level, %', p.kind, p.subject, level;
  END IF;
  RETURN format('%s/%s/%s:%s/%s/%s', coalesce(p.collector_id, '-'), coalesce(p.endpoint_id, '-'),
                coalesce(p.host, '-'), coalesce(p.port::text, '-'), coalesce(p.unit_id::text, '-'),
                coalesce(p.serial, '-'));
END
$$;

-- The subject a problem at level would have, from its key columns; a
-- meter_store's store is the one part not among them, so its own is kept.
CREATE FUNCTION pg_temp.subject_at(level text, p health.problems) RETURNS text
LANGUAGE sql AS $$
  SELECT CASE level
    WHEN 'collector' THEN p.collector_id
    WHEN 'endpoint' THEN p.endpoint_id
    WHEN 'target' THEN format('%s unit %s', p.endpoint_id, p.unit_id)
    WHEN 'meter' THEN p.serial
    WHEN 'meter_store' THEN p.serial || ' ' || substring(p.subject FROM ' (\S+)$')
    WHEN 'place' THEN format('%s:%s unit %s via %s', p.host, p.port, p.unit_id, p.collector_id)
  END
$$;
