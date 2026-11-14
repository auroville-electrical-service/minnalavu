# central

The central store, `minnalavu` in the names table: PostgreSQL with
TimescaleDB, and PostgREST in front of it as the only thing collectors talk to.
In phase 1 it is configuration, not an application: the schema, the ingest
function and the role grants are the code, as SQL migrations with SQL tests.

The directory is not named `minnalavu/`, since that is the repo itself.

## Layout

- `migrations/`: plain SQL, applied in order by [dbmate](https://github.com/amacneil/dbmate)
  (one static binary; it records applied versions in `public.schema_migrations`).
  Forward only: a rollback would drop raw data, so a mistake is undone by a new
  migration. Never edit one that has been applied anywhere that matters.
- `test/*.sql`: the SQL tests, each a transaction that is rolled back; helpers in
  `test/lib/assert.sql`.
- `bin/`: `migrate`, `test`, `dev-db` (dev only), `collector-token`, `alert`
  and `test-alert`.

## Schemas and roles

- `store`: the data. `readings` and `missed_reads` are hypertables. A reading
  is keyed on `(meter_serial, register_key, read_at)`, the serial being the one
  the meter reported, and carries the product code it reported too. A missed
  read is a fact about an address, keyed on `(collector_id, endpoint_host,
  endpoint_port, unit_id, register_key, read_at)`, and carries the serial read
  in its round, or none. `firmware_reads`: a meter's software and firmware
  names as read, keyed like a missed read on its address and time, a name it
  did not give NULL. `batches` (one row per batch, as
  first received), `uploads` (every arrival of a batch, with the collector's
  backlog), `reading_conflicts` (a reading whose key was already taken by one
  with other content) and `collectors`. Nothing in `store` can be updated,
  deleted or truncated, by any role (triggers).
- `api`: what PostgREST exposes. One function, `api.ingest(jsonb)`: `POST
  /rpc/ingest` with a batch (`contract/schema/batch.v1.schema.json`) as the body.
- `admin`: operator functions, run as the database owner.
- `registry`: the device registry (below).
- `health`: views of collection health, the only thing the role `monitor` may read.

Roles: PostgREST logs in as `authenticator` (no privileges of its own) and
switches to the role the request's token names. Each collector has a role,
`collector_<id>`, which inherits from `collector` the right to execute
`api.ingest` and nothing else. The ingest function identifies the caller by
that role, never by anything in the batch.

## The device registry

Which endpoints and meters exist, where each sits and how it is polled, from
when, in the shape of the collector's polling config
(`alavi/lib/alavi/config.ex`), so that config can later be served from here.
Collectors are `store.collectors`.

- `registry.endpoints` and `registry.meters` hold identities only: an endpoint
  by an operator-chosen id (so it survives a new address or a move to another
  collector), a meter by its serial (as readings carry it).
- `registry.endpoint_versions` and `registry.meter_versions` hold their state.
  Each row is the whole state from `valid_from` until the next row's: a move,
  a new interval, a retirement or a swap adds a row. Nothing in `registry` is
  ever updated or deleted (triggers refuse it, even for the owner). A mistake
  is corrected by a row with the same `valid_from`; the one recorded last
  holds, and the mistaken row is kept.
- `registry.endpoint_history` and `registry.meter_history` give the state that
  holds over each period `[valid_from, valid_to)`; `valid_to` is NULL while
  open.
- `registry.meter_swaps`: a meter replaced by another in the same place.

After every change, the whole history is checked, so a back-dated change is
judged against what came after it too: an endpoint's host and port appear once
per collector, a unit id once per endpoint, and a meter is in service only
while its endpoint is. A change that breaks one is refused (SQLSTATE 23P01).

Admin functions, as the owner, with named arguments; each takes the time it
holds from, which may be in the past:

    SELECT admin.register_endpoint(endpoint_id => 'site_a_chain_1', valid_from => '2026-11-01T00:00Z',
      collector_id => 'pilot_01', host => '10.0.0.21', port => 502, framing => 'tcp',
      polled_by_other_system => false, timeout_ms => 1000, max_timeouts => 3, retries => 2,
      busy_backoff_ms => 500, reconnect_backoff_min_ms => 1000,
      reconnect_backoff_max_ms => 60000, interval_ms => 900000);
    SELECT admin.register_meter(serial => '…', valid_from => '…', endpoint_id => 'site_a_chain_1',
      unit_id => 1, profile => 'elite_440', interval_ms => NULL);   -- NULL: the endpoint's

- `admin.change_endpoint(…)`, `admin.change_meter(…)`: the same arguments as
  register; the whole new state (readdress, move, retime, correct).
- `admin.retire_endpoint(endpoint_id, valid_from)` (its meters must be moved or
  retired first), `admin.retire_meter(serial, valid_from)`.
- `admin.swap_meter(old_serial, new_serial, swapped_at, profile)`: the old
  meter retires and the new one takes its endpoint, unit id and interval.

Hierarchy edges and meter-to-account assignments are not kept here. They
belong to `minkanakku`, which maps meters to accounts and refers to meters by
serial.

## Health views and the monitor role

Read over an SSH tunnel; nothing is exposed. All of them are as of `now()`.

- `health.collectors`: per collector, last upload and last reading, clock
  source and last sync (of the batch first received last), the backlog of its
  latest upload (events, bytes, batches, oldest, capacity, share used,
  refused, discarded files, quarantined), and missed reads within the lookback,
  by reason. A collector is judged only while it has an endpoint in service.
- `health.meters`: per registered meter, where it is, its expected interval,
  last reading, missed reads within the lookback by reason, and whether it is
  silent. A meter is expected to be read while it and its endpoint are in
  service and no other system polls the endpoint. A missed read counts for
  the meter whose serial it carries or, with none, for the meter registered at
  its address now.
- `health.unregistered_serials`: serials with readings within the lookback
  that are not in the registry.
- `health.unregistered_serial_places`: the same serials, one row per place
  (collector, host, port, unit) each was read at within the lookback.
- `health.misplaced_serials`: registered serials read within the lookback at
  a place (collector, host, port, unit) other than where the registry put them
  when each reading was taken; one row per serial and place.
- `health.meter_firmware`: per serial, the latest names it reported, the
  record before them, and whether they differ.
- `health.problems`: one row per problem, `(kind, subject)` naming it and
  `detail` describing it now. Kinds: `collector_silent` (no upload for
  `collector_silent_after`), `meter_silent` (no reading for
  `meter_silent_intervals` × its interval, counted from when it came into
  service if later; not listed when its collector is silent),
  `backlog_near_capacity` (bytes at or above `backlog_near_capacity` of the
  buffer), `backlog_refused`, `backlog_discarded`, `backlog_quarantined` (above
  zero in the latest upload; `refused` counts since the collector started, so
  it clears on a restart), `unregistered_serial`, `misplaced_serial` (one
  per serial, every place it was read in its detail),
  `serial_at_several_places` (an unregistered serial read at more than one
  place: two meters reporting one serial, one meter reachable two ways, or a
  move; every place in its detail) and `firmware_changed` (a serial whose
  latest names differ from its record before them, while the batch that
  brought the latest arrived within the lookback, so a weeks-late change is
  flagged when it arrives).
- `health.thresholds`: the thresholds in force, from
  `registry.health_thresholds` (append-only; the last row set holds). Change
  them as the owner:

      SELECT admin.set_health_thresholds(collector_silent_after => '1 hour',
        meter_silent_intervals => 4, backlog_near_capacity => 0.8, lookback => '1 day');

The role `monitor` may select from these views and nothing else: no raw
table, no registry table, nothing in `api` or `admin`, no function, no writes
(`test/grants.sql`). It cannot log in; a login is a member of it, one per
person or job:

    CREATE ROLE alert_job LOGIN PASSWORD '…' IN ROLE monitor;

## The alert job

`bin/alert`, run by cron on the VPS: it reads `health.problems` as a member of
`monitor` and mails when they change. Bash, `psql` and `curl` (which speaks
SMTP), so nothing to install beyond what the VPS has for Postgres; it needs
bash 5 and, in the crontab line below, `flock` (util-linux).

- **Policy: one mail per change.** A mail goes out when a problem appears or
  clears, listing what is new, what cleared and what is still open; nothing
  is sent while the problems stay as last reported, and nothing when all is
  well. If the health views cannot be read (the database is down, the login
  fails), that is a problem too: mailed once, cleared when they can be read
  again, and every such run exits 1.
- **State: a local file** (`ALERT_STATE_FILE`, one `kind<TAB>subject` per line
  open as last reported), written only after a mail is sent, so a failed send
  is retried on the next run. Kept on the VPS rather than in the database so
  that `monitor` stays strictly read-only; losing it costs at most one repeat
  mail.
- **Config, all required** (the run stops with status 2, naming what is
  wrong, before reading or sending anything): `ALERT_DB_URL` (a connection
  string, so the database may be elsewhere; a password belongs in `~/.pgpass`
  rather than the URL), `ALERT_SMTP_URL` (`smtps://host:465` or
  `smtp://host:587`), `ALERT_SMTP_TLS` (`required`; `none` only for a local
  mail catcher), `ALERT_SMTP_USER`, `ALERT_SMTP_PASSWORD` (handed to curl on a
  pipe, not on its command line), `ALERT_FROM`, `ALERT_TO` (comma-separated)
  and `ALERT_STATE_FILE`.
- Without `--apply` it prints the mail it would send and keeps no state.

On the VPS, with the settings as `export ALERT_…=…` lines in
`/etc/minnalavu/alert.env` (mode 600, owned by the job's user), every five
minutes:

    */5 * * * * flock -n /run/lock/minnalavu-alert.lock sh -c '. /etc/minnalavu/alert.env && exec bash /opt/minnalavu/central/bin/alert --apply' >>/var/log/minnalavu/alert.log 2>&1

`flock -n` skips a run while the last one is still going, so two runs never
send the same mail.

## Answers from `POST /rpc/ingest`

- 200: stored, or already stored (a resend). The body names the `batch_id` and
  counts readings `received`, `inserted`, `duplicate` and `conflicting`,
  missed reads `received`, `inserted` and `duplicate`, and firmware reads
  `received`, `inserted`, `duplicate` and `conflicting` (a conflicting one is
  counted, not kept).
- 422 (`PT422`): the batch does not match the schema; the message names the field.
- 409 (`PT409`): the batch id was already sent by another collector.
- 400 (`PGRST102`): the body is not JSON.
- 401 / 403: no token, a bad or expired token, or a role that is not a
  registered collector.

## Running it

PostgREST does not serve HTTPS ("To keep the code small and focused we do not
implement HTTPS", PostgREST v16 docs), so in production a reverse proxy
terminates TLS in front of it; collectors refuse plain HTTP. PostgREST takes
the database as a connection string (`db-uri`), so the database may run on
another machine; Postgres itself is never exposed beyond PostgREST.

PostgREST settings: `db-uri` (as `authenticator`), `db-schemas = api`,
`jwt-secret`, no `db-anon-role` (anonymous requests are refused), and
`openapi-mode = disabled`.

Applying migrations, as the database owner (a superuser: the first one creates
the TimescaleDB extension and the roles):

    bin/migrate 'postgres://owner@host:5432/minnalavu?sslmode=require'           # what is pending
    bin/migrate 'postgres://owner@host:5432/minnalavu?sslmode=require' --apply

Once, after the first migration: `ALTER ROLE authenticator LOGIN PASSWORD '…'`,
with the password PostgREST's `db-uri` uses.

A new collector, as the owner:

    SELECT admin.create_collector('pilot_01');   -- returns its role, collector_pilot_01

then its token, signed with PostgREST's `jwt-secret`, for the collector's
`ALAVI_SERVER_TOKEN`:

    JWT_SECRET=… bin/collector-token pilot_01 365    # or never

## Dev and tests

Through `bin/dev central …`, with `docker compose up -d timescale postgrest mailpit`:

    bin/dev central bin/test             # the SQL tests, on a fresh minnalavu_test database
    bin/dev central bin/test-alert       # bin/alert on a fresh minnalavu_alert_test database,
                                         # mailing the mailpit catcher (its mailbox is cleared)
    bin/dev central bin/dev-db --apply   # migrate the dev database PostgREST serves
