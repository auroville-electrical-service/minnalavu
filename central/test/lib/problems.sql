-- The key columns of the one problem of a kind and subject, as
-- collector/endpoint/host:port/unit/serial with - for NULL, for comparing
-- with a written-out value.

CREATE FUNCTION pg_temp.keys(want_kind text, want_subject text) RETURNS text
LANGUAGE sql AS $$
  SELECT format('%s/%s/%s:%s/%s/%s', coalesce(collector_id, '-'), coalesce(endpoint_id, '-'),
                coalesce(host, '-'), coalesce(port::text, '-'), coalesce(unit_id::text, '-'),
                coalesce(serial, '-'))
  FROM health.problems
  WHERE kind = want_kind AND subject = want_subject
$$;
