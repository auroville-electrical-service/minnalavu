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
- `bin/`: `migrate`, `load-profiles`, `test`, `dev-db` (dev only),
  `collector-token`, `alert` and `test-alert`.

## Schemas and roles

- `store`: the data. `readings` and `missed_reads` are hypertables. A reading
  is keyed on `(meter_serial, register_key, read_at)`, the serial being the one
  the meter reported, and carries the product code it reported too, its value
  as sent, and the profile version it was decoded under; no raw words, unit or
  kind (the profile catalog, below, gives those). A missed
  read is a fact about an address, keyed on `(collector_id, endpoint_host,
  endpoint_port, unit_id, register_key, read_at)`, and carries the serial read
  in its round, or none, its profile version, and any raw words no value came
  of. `firmware_reads`: a meter's software and firmware
  names as read, with the serial and product code read with them, keyed on
  `(collector_id, endpoint_host, endpoint_port, unit_id, read_at)`, a name it
  did not give NULL; a collector sends one when something in it changed, and
  the first after it starts, so the latest record holds until the next.
  `clock_checks`: each SNTP query a collector made of its clock, keyed on
  `(collector_id, t1)`, with its trigger, server and outcome; the collector's
  `t1` and `t4` as `timestamptz` (microseconds), and, when it was answered, the
  server's `t2_unix` and `t3_unix` as Unix time in `numeric` seconds (exact to
  the nanosecond, which `timestamptz` cannot hold), the address, stratum, leap
  indicator and reference id; a kiss-o'-death keeps its address and reference id
  (the kiss code). The views on it are under *Clock checks* below.
  `latency_days`: each meter's request latency for a UTC day as one poller
  counted it, keyed on `(collector_id, endpoint_host, endpoint_port, unit_id,
  day, poller_started_at)`, so a restart's part of a day is a row of its own:
  the bucket version, retries, timeouts, the exact `max_ms` (NULL when nothing
  answered) and `buckets`, every bucket's count. The views on it are under
  *Request latency* below.
  `stored_entries` (a hypertable on `meter_time`): each quantity of each
  history, snapshot and load-survey entry a collector copied from a meter,
  keyed on `(meter_serial, store, register_key, meter_time)`, the meter's own
  stamp as a `timestamp` with no zone (a load-survey entry's is its
  interval's start, and only it has `interval_s`), never the slot it was read
  at. It carries its value as sent, the profile version it was decoded under
  (a foreign key to that version's stored quantity, so its unit and kind are
  the catalog's), the product code, the slot, `copied_at` (the collector's
  clock), any request id as first sent, and where it was copied from; no raw
  words, unit or kind. An entry copied again that says the same (value,
  interval, profile version, product code) is a duplicate, whatever its slot,
  copy time or address; one that says otherwise goes to
  `stored_entry_conflicts`, beside the stored one, which stands.
  `meter_clock_reads`: a meter's clock as read beside the collector's, raw,
  keyed on `(collector_id, endpoint_host, endpoint_port, unit_id,
  collector_at)`, with the serial, profile version and `meter_time` (no
  zone); a read that differs from the stored one under its key goes to
  `meter_clock_read_conflicts`, beside the stored one, which stands. Offsets
  against true time are for views, through the clock checks.
  `batches` (one row per batch, as first received), `uploads` (every arrival of a batch, with the collector's
  backlog), `reading_conflicts` (a reading whose key was already taken by one
  with other content) and `collectors`. Nothing in `store` can be updated,
  deleted or truncated, by any role (triggers).
- `api`: what PostgREST exposes. Two functions: `api.ingest(jsonb)`, `POST
  /rpc/ingest` with a batch (`contract/schema/batch.v1.schema.json`) as the
  body; and `api.collector_config()`, `GET /rpc/collector_config`, the calling
  collector's polling config (below).
- `admin`: operator functions, run as the database owner.
- `registry`: the device registry (below).
- `health`: views of collection health, the only thing the role `monitor` may read.
- `jobs`: requests for reads on demand, the only thing the role
  `minkanakku_staff` may touch (below).

Roles: PostgREST logs in as `authenticator` (no privileges of its own) and
switches to the role the request's token names. Each collector has a role,
`collector_<id>`, which inherits from `collector` the right to execute
`api.ingest` and `api.collector_config` and nothing else. Both identify the
caller by that role, never by anything it sends.

## The profile catalog

`store.latency_bucket_versions`: each version of `contract/latency/`'s
bucket bounds, loaded with the profiles and never changed in the same way.

`store.profile_versions` and `store.profile_registers`: each version of each
profile in `contract/profiles/`, and per register its table, address, type,
word order and decimals (the decode; a float has no decimals), unit and kind.
Every reading and missed read names a profile version and a register of it
(a foreign key), so its unit and kind are the catalog's, and a value's
raw words are recoverable from the value and the decode. Nothing in the
catalog is ever updated or deleted (triggers refuse it, even for the owner).

`store.profile_stored`: per version, each stored quantity of its `stored`
section by store and register key, with its table, address (history and
snapshot) or parameter number (load survey), decode, unit and kind. It
refuses a `cumulative` quantity in the load survey and an `interval` one in
any other store: only a cumulative quantity is ever differenced as energy.
Every stored entry names one of these rows, so a cumulative quantity can
never be recorded as a load-survey entry, nor an interval one in a history
or snapshot.

Load it as the owner after migrating, and again whenever a profile gains a
version:

    bin/load-profiles 'postgres://owner@host:5432/minnalavu?sslmode=require'           # what it would load
    bin/load-profiles 'postgres://owner@host:5432/minnalavu?sslmode=require' --apply

Every file, profiles and bucket versions, is loaded in one transaction. A
bucket version already loaded is left as it is when its bounds are the same,
and refused otherwise. A profile version already loaded is left as
it is when its file still names the same registers and stored quantities
with the same decode, address or parameter, unit and kind (a change to
`verified_on_device` or a source is no change), and refused otherwise,
loading nothing: a loaded version never changes, so a correction is a new
version.

## Request latency

Views over `store.latency_days`, as the owner. Percentiles are read as the
collector's status page reads them: nearest rank, the upper bound of the
smallest bucket holding at least p % of the answers, never above the exact
max (the max itself above the last bound), NULL when nothing answered.
Buckets merge only within a bucket version, so each figure names one.

- `store.latency_meter_days`: per meter (collector, host, port, unit), UTC day
  and bucket version, its entries merged: answered (the buckets' sum),
  retries, timeouts, p50, p90, p99 and max, in ms.
- `store.latency_endpoint_days`: the same per endpoint, every meter's entries
  merged, with how many meters.

## Clock checks

Views over `store.clock_checks` and `store.uploads`, as the owner (no other
role may read them). Figures are exact `numeric` seconds; an offset is what to
add to the collector's clock to get the reference's.

- `store.clock_offsets`: per answered check, the offset
  ((t2 − t1) + (t3 − t4)) / 2, the delay (t4 − t1) − (t3 − t2) and the error
  bound delay / 2, with t2 and t3 shown as `timestamptz` too (cut to
  microseconds) and the reference id decoded.
- `store.upload_clock_offsets`: per upload, the fallback when NTP does not
  answer: `received_at − sent_at`, a one-sided bound. The true offset is this
  less the unknown transit time, so at most this; it is never an NTP-grade
  offset.
- `store.clock_check_references`: each reference id decoded: a kiss code
  (`RATE`, `DENY`) or a stratum 1 source (`GPS`) as text, any other stratum's
  as a dotted quad.
- `store.ungrounded_readings`: readings with no answered check by their
  collector within 48 hours before or after them, by the collector's clock,
  with the nearest answered checks either side. Nothing is refused for it, and
  readings carry no such column.
- `store.energy_drops`: per cumulative reading lower than the one before it
  of the same serial and register by `read_at` (a reset, a swap, a write, or
  the clock stepping back), both readings with their batch's clock claim
  (`clock_source`, `clock_last_sync_at`) and whether an answered check grounds
  each. Compared exactly, Wh against kWh. `suspect` where neither reading is
  grounded: the drop may be the clock, not the meter.

## The device registry

Which endpoints, polling targets and meters exist, where each sits and how it
is polled, from when, in the shape of the collector's polling config
(`contract/config/config.v1.schema.json`), so that config can later be served
from here. `test/config.sql` holds the registry's checks to that schema and to
`contract/fixtures/config.v1.cases.json`: the same ranges, framings, host,
profile name and serial rules.
Collectors are `store.collectors`.

- `registry.endpoints`, `registry.targets` and `registry.meters` hold
  identities only: an endpoint by an operator-chosen id (so it survives a new
  address or a move to another collector), a target by its endpoint and unit
  id (a place to poll, whatever meter answers there, so a unit is polled
  before its serial is known), a meter by its serial (as readings carry it).
- `registry.endpoint_versions`, `registry.target_versions` and
  `registry.meter_versions` hold their state: a target's profile, interval
  and retry interval (NULL: its endpoint's), and the target a meter is placed
  at; each value stored once. An interval, an endpoint's or a target's,
  divides a day (86,400,000 ms), since rounds fall on slots from the
  collector's local midnight; a retry interval need not.
  Each row is the whole state from `valid_from` until the next row's: a move,
  a new interval, a retirement or a swap adds a row. Nothing in `registry` is
  ever updated or deleted (triggers refuse it, even for the owner). A mistake
  is corrected by a row with the same `valid_from`; the one recorded last
  holds, and the mistaken row is kept.
- `registry.endpoint_history`, `registry.target_history` and
  `registry.meter_history` give the state that
  holds over each period `[valid_from, valid_to)`; `valid_to` is NULL while
  open.
- `registry.meter_swaps`: a meter replaced by another in the same place.

After every change, the whole history is checked, so a back-dated change is
judged against what came after it too: an endpoint's host and port appear once
per collector, one meter in service at a target at a time, a target in
service only while its endpoint is, and a meter only while its target is. A
change that breaks one is refused (SQLSTATE 23P01).

Admin functions, as the owner, with named arguments; each takes the time it
holds from, which may be in the past:

    SELECT admin.register_endpoint(endpoint_id => 'site_a_chain_1', valid_from => '2026-11-01T00:00Z',
      collector_id => 'pilot_01', host => '10.0.0.21', port => 502, framing => 'tcp',
      polled_by_other_system => false, timeout_ms => 1000, max_timeouts => 3, retries => 2,
      busy_backoff_ms => 500, reconnect_backoff_min_ms => 1000,
      reconnect_backoff_max_ms => 60000, interval_ms => 900000,
      retry_ms => 1800000);   -- copies nothing
    SELECT admin.register_target(endpoint_id => 'site_a_chain_1', unit_id => 1,
      valid_from => '…', profile => 'elite_440', interval_ms => NULL,
      retry_ms => NULL);   -- NULL: the endpoint's
    SELECT admin.register_meter(serial => '…', valid_from => '…', endpoint_id => 'site_a_chain_1',
      unit_id => 1);

- `admin.change_endpoint(…)`, `admin.change_target(…)`, `admin.change_meter(…)`:
  the same arguments as register; the whole new state (readdress, move,
  reprofile, retime, correct). An endpoint copies its meters' stored entries
  only when `copy => true`: `register_endpoint` takes it optionally, off when
  left out, and `change_endpoint` requires it, so a change cannot switch
  copying off unseen. `retry_ms`, how soon a meter that gave no reading in a
  round is read again, has no default in any of the four that set an
  interval: register and change, endpoint and target.
- `admin.set_copy_window(collector_id, valid_from, start_time, end_time)`:
  the window of the collector's local wall clock that copies run in, in
  whole minutes, from `valid_from`; an end before the start crosses
  midnight. A collector with no window in force is served a config without
  one, which it refuses.
- `admin.retire_endpoint(endpoint_id, valid_from)` (its targets must be
  retired first), `admin.retire_target(endpoint_id, unit_id, valid_from)` (its
  meter must be moved or retired first), `admin.retire_meter(serial, valid_from)`.
- `admin.swap_meter(old_serial, new_serial, swapped_at)`: the old meter
  retires and the new one takes its target; a new meter of another model is
  `admin.change_target` from the same time.

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
- `health.meters`: per registered meter, where it is, its target's profile and
  expected interval,
  last reading, missed reads within the lookback by reason, and whether it is
  silent. A meter is expected to be read while it and its endpoint are in
  service and no other system polls the endpoint. A missed read counts for
  the meter whose serial it carries or, with none, for the meter registered at
  its address now.
- `health.meter_rounds`: per meter expected to be read, the rounds due since
  the lookback or its coming into service (whole intervals, at its interval
  now) and the rounds it was read in since then, wherever it was read. A
  round is its readings run together: one more than half an interval after
  the last starts the next. Rounds not uploaded yet count as not read. No
  problem kind is raised on it.
- `health.targets`: per registered target, as registered now: its profile,
  the meter placed there now (if any), its expected interval, the last
  reading and the last missed read at its unit whatever serial they carry, at
  each address its endpoint had while in service, and whether it is silent.
  A target is expected to be read while it and its endpoint are in service
  and no other system polls the endpoint.
- `health.endpoints`: per registered endpoint, as registered now, the reads
  due at it within the lookback (one per register: a reading or a missed
  read), counted at each address it had while in service and by its
  collector; missed reads by reason; `failed_reads`, the missed reads other
  than `decode` and `profile_mismatch` (the meter answered); `error_rate`,
  failed over due, NULL when none was due; and `erroring`, at or above
  `endpoint_error_rate` while in service and not polled by another system.
  Counted on an address and time index, so a run costs the lookback's
  readings, never a scan of all of them. Request latency is in
  `health.endpoint_latency`.
- `health.endpoint_latency`: per registered endpoint, as registered now, a
  row per UTC day overlapping the lookback and bucket version, from
  `store.latency_endpoint_days` at each address it had while in service that
  day: meters, entries, answered, retries, timeouts, p50, p90, p99 and max.
  Only the lookback's days are read (by index on the day). No problem kind
  is raised on it.
- `health.unregistered_serials`: serials with readings within the lookback
  that are not in the registry.
- `health.unregistered_serial_places`: the same serials, one row per place
  (collector, host, port, unit) each was read at within the lookback.
- `health.place_serials`: places (collector, host, port, unit) whose readings
  and missed reads within the lookback carry more than one serial, registered
  or not; one row per place and serial, with its readings, its missed reads
  and when it was first and last seen there.
- `health.misplaced_serials`: registered serials read within the lookback at
  a place (collector, host, port, unit) other than where the registry put them
  when each reading was taken; one row per serial and place.
- `health.meter_firmware`: per serial, the latest names it reported, when
  they were first read and arrived (a resend after a restart does not move
  that), the latest earlier record whose names differ, and whether there is one.
- `health.collector_clocks`: per collector, its last clock check (by its own
  clock) and outcome, the server's time, offset and error bound of its last
  answered one, the offset bound of its latest upload, and whether it is
  unchecked: in service, not silent, and no answered check within 48 hours by
  the server's clock (counted from registration when it has none).
- `health.energy_drops`: the drops in `store.energy_drops` at or just after
  a reading whose batch arrived within the lookback, found by index from those
  batches, never by a scan of the readings.
- `health.copy_targets`: per registered target copied now (it and its
  endpoint in service, `copy` on, no other system polling it): since when its
  endpoint has copied without a break, the serial its last meter-clock read
  at the unit's address found (none until one comes), when that serial's
  clock was first read anywhere (when a collector able to copy first saw
  it), the meter's offset from UTC as that read measured it (zone and drift
  together), and the collector's last upload. Meter times below are placed
  beside the server's by that offset.
- `health.missed_snapshots`: per copied 440, each meter day whose snapshot
  (stamped at the meter's midnight, replaced at the next: a 440 keeps one)
  was not copied: taken after its endpoint began copying and the meter was
  first seen, replaced at least `snapshot_missed_margin` before the meter's
  clock at the collector's last upload, and replaced within the lookback.
  Each day is one lookup by serial, store and stamp range.
- `health.copy_stores`: per copied meter and each store its profile is judged
  on (440: history, load survey; 500: history, snapshot, load survey), the
  newest entry copied and whether the store is behind: no entry stamped later
  than its `*_behind_after` before the meter's clock at the collector's last
  upload, and copied and seen since before then. `behind` is one lookup by
  serial, store and stamp range; `newest_entry` one per register key.
- `health.meter_clock_offsets`: per meter-clock read, its collector's
  answered clock check nearest it within 48 hours, and the meter's offset
  from UTC that check gives (its zone and error together); no check within
  the bound, no offset.
- `health.meter_clock_steps`: per grounded meter-clock read whose batch
  arrived within the lookback, its step from the same serial's previous
  grounded read, when that passes `meter_clock_step_after`: the clock was
  set or stopped between the two.
- `health.meter_clocks`: per target in service, the last grounded
  meter-clock read at its address, its offset, and its distance from the
  median offset of its collector's meters (a collector's meters share a
  zone, so the zone cancels). Far past `meter_clock_far_after`, judged only
  where the collector has at least three such meters.
- `health.copy_meters`: per copied meter, the stores behind in
  `health.copy_stores`, the days missed in `health.missed_snapshots`, and its
  polling interval; polled slowly when its copies fail and it is polled less
  often than `copy_failing_interval`.
- `health.problems`: one row per problem, `(kind, subject)` naming it and
  `detail` describing it now. Kinds: `collector_silent` (no upload for
  `collector_silent_after`), `clock_unchecked` (unchecked in
  `health.collector_clocks`; its detail says since when and what the last check
  was), `meter_silent` (no reading for
  `meter_silent_intervals` × its interval, counted from when it came into
  service if later; not listed when its collector or its target is silent),
  `target_silent` (no reading at the unit for `meter_silent_intervals` × its
  interval, counted from when it came into service if later, whatever missed
  reads there were; not listed when its collector is silent; its subject is
  `<endpoint> unit <n>`, its detail the last missed read, the address, profile
  and meter placed),
  `endpoint_errors` (erroring in `health.endpoints`; its detail gives the
  failed and due reads, the rate, the missed reads by reason and the
  address), `backlog_near_capacity` (bytes at or above
  `backlog_near_capacity` of the buffer), `backlog_refused`,
  `backlog_discarded`, `backlog_quarantined` (above zero in the latest
  upload; `refused` counts since the collector started, so it clears on a
  restart), `config_refused` (the latest upload reports a served config the
  collector refused; its detail gives that digest, the reason and the digest
  it still applies), `unregistered_serial`, `misplaced_serial` (one
  per serial, every place it was read in its detail),
  `serial_at_several_places` (an unregistered serial read at more than one
  place: two meters reporting one serial, one meter reachable two ways, or a
  move; every place in its detail), `several_serials_at_place` (a place whose
  readings carry more than one serial: a swap, or two meters answering one
  address; each serial's readings and times in its detail, so a handover
  shows apart from interleaving), `firmware_changed` (a serial whose
  latest names differ from an earlier record, while the batch that first
  brought the latest names arrived within the lookback, so a weeks-late change
  is flagged when it arrives, and a resend neither hides nor renews it),
  `energy_backwards` (a serial with a drop in `health.energy_drops`; each drop,
  both readings' clock signals and whether it is suspect in its detail),
  `snapshot_missed` (a serial in `health.missed_snapshots`; its meter days,
  the meter's clock as last read and the address in its detail) and
  `copy_behind` (a store behind in `health.copy_stores`, subject
  `<serial> <store>`; its newest entry copied and the threshold in its
  detail). Both are measured at the collector's last upload, so a collector
  gone quiet shows as `collector_silent`, not as copies missed. Then
  `meter_clock_step` (a serial in `health.meter_clock_steps`; each step, the
  reads either side and the address in its detail), `meter_clock_far` (far in
  `health.meter_clocks`; its offset, its distance from the median and of how
  many meters) and `copy_failing_polled_slowly` (polled slowly in
  `health.copy_meters`; what fails, its interval and the threshold).
- `health.stored_entries`, `health.stored_entry_conflicts`,
  `health.meter_clock_reads` and `health.meter_clock_read_conflicts`: every
  row of their `store` tables, the first and third with `received_at`, when
  the batch that brought it first arrived, so a late copy is found by
  arrival, as readings are.
- `health.thresholds`: the thresholds in force, from
  `registry.health_thresholds` (append-only; the last row set holds). Change
  them as the owner:

      SELECT admin.set_health_thresholds(collector_silent_after => '1 hour',
        meter_silent_intervals => 4, backlog_near_capacity => 0.8, lookback => '1 day',
        endpoint_error_rate => 0.05, snapshot_missed_margin => '1 hour',
        history_behind_after => '62 days', snapshot_behind_after_elite_500 => '14 days',
        load_survey_behind_after_elite_440 => '7 days', load_survey_behind_after_elite_500 => '30 days',
        meter_clock_step_after => '5 minutes', meter_clock_far_after => '15 minutes',
        copy_failing_interval => '30 minutes');

  `endpoint_error_rate`'s first value, 0.05, is a guess until the pilot's
  figures say what a healthy chain misses.
  So are the first values of `snapshot_missed_margin` (1 hour),
  `history_behind_after` (62 days), `snapshot_behind_after_elite_500` (14
  days), `load_survey_behind_after_elite_440` (7 days) and
  `load_survey_behind_after_elite_500` (30 days), until the pilot's copies show
  what its meters keep: each sits below what the pilot's meters of that model
  held (a 440 34 days of load survey, a 500 52 snapshots and 332 days; six
  histories each). And of `meter_clock_step_after` (5 minutes, far above
  a meter's drift between reads), `meter_clock_far_after` (15 minutes) and
  `copy_failing_interval` (30 minutes, the 440's load-survey interval).

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

## Reads on demand and the role minkanakku_staff

`minkanakku`'s staff side asks a collector to read meters now; the collector
learns of it from its next upload's answer (a doorbell on a message broker
will wake it sooner), runs it, and tags what it reads with the request's id.

- `jobs.requests` (with `jobs.request_meters`): one row per request, the
  collector, the kind (only `read_on_demand`), the meters by serial, an opaque
  `requester` reference `minkanakku` resolves (1 to 200 characters, no control
  characters; nothing about the person), `requested_at` and `expires_at`, an
  hour later.
- `jobs.request_readings` and `jobs.request_missed_reads` link a request to the
  readings and missed reads that came for it, by their keys. Raw readings carry
  no request: the link is a row of its own, so a stored reading is never
  touched, and a resend links nothing twice. Readings carrying an id that is
  not one of the sending collector's requests are stored as any other and
  linked to nothing.
- `jobs.request_status`: each request with its meters, how many readings and
  missed reads have come for it, when the first came (`answered_at`), and its
  `state` as of `now()`: `answered` once any reading or missed read has come
  (even after expiry); else `expired` once `expires_at` has passed; else
  `pending`. A request that is never answered stays `expired`, as a record.
- Nothing in `jobs` is ever updated or deleted (triggers refuse it, even for
  the owner).

The role `minkanakku_staff` may call one function and read one view, and
nothing else (`test/grants.sql`); no other role may call the function. It
cannot log in; a login is a member of it, as for `monitor`. One login may
hold both roles, and so reach what each grants; it may hold no other role,
own nothing, and be granted nothing by name.

`minkanakku`'s read-only role, not built yet, will read `stored_entries`,
`stored_entry_conflicts`, `meter_clock_reads` and `meter_clock_read_conflicts`
beside the readings and the catalog: a widening of that interface, to be changed with the same care.

    SELECT jobs.request_job(collector_id => 'pilot_01', kind => 'read_on_demand',
      meters => ARRAY['…'], requester => '…');          -- returns the request id

It inserts the request and touches nothing else. Each meter must be in
service now, on an endpoint in service now with that collector, which no
other system polls; anything else is refused with SQLSTATE 22023, naming what
is wrong.

When ingest commits a batch that links readings or missed reads to a
request, it sends `NOTIFY request_answered` with the payload
`{"request_id": …, "batch_id": …, "readings": n, "missed_reads": n}` (what this
batch newly linked); a resend that links nothing new sends nothing. Any role
may `LISTEN`, and any role with a connection may `NOTIFY` on that channel, so a
notice says only "look again": read `jobs.request_status`.

## The served polling config

`GET /rpc/collector_config` (or `POST` with `{}`), with a collector's token,
answers with that collector's polling config as of now, in
`contract/config/config.v1.schema.json`'s schema version 1: its copy window
in force, as `HH:MM`; its endpoints in service, ordered by host (by its
bytes) and port, `polled_by_other_system` and `copy` as registered, each with its targets in service by unit id, each target's
profile, its interval only when it has its own, and the serial of the meter
placed there when there is one. It is served as the registry holds it, valid
or not: a collector with no copy window in force gets none, one with no
endpoint in service gets none, and an endpoint
with no target in service no meters, which the collector refuses. Nor is a
serial checked against its profile's serial registers here; that is the
collector's parser's. Any other role gets 403.

Every ingest answer carries `config_digest`, the digest of that document as
`contract/fixtures/config.v1.digests.json` defines it, so a collector learns
of a change from its next batch or heartbeat. The backlog's `config` (the
digest the collector applies, and one it refused with the reason) is kept
per upload in `store.uploads` and shown in `health.collectors`.

## Answers from `POST /rpc/ingest`

- 200: stored, or already stored (a resend). The body names the `batch_id` and
  counts readings `received`, `inserted`, `duplicate` and `conflicting`,
  missed reads `received`, `inserted` and `duplicate`, and firmware reads
  `received`, `inserted`, `duplicate` and `conflicting` (a conflicting one is
  counted, not kept), and clock checks, latency entries, stored entries and
  meter-clock reads the same (a conflicting stored entry is kept in
  `store.stored_entry_conflicts`, a conflicting meter-clock read in
  `store.meter_clock_read_conflicts`), and `config_digest` (above). Stored
  entries and meter-clock reads are counted per upload in `store.uploads` too, as
  readings and missed reads are. `jobs`, when the collector has
  pending requests, lists them oldest first, each with its `request_id`, `kind`,
  `meters` (serials), `requested_at` and `expires_at`; a request is listed
  until a reading or missed read for it arrives or it expires, so a collector
  runs each id once.
  `unknown_requests`, when the batch carried request ids that are not the
  collector's requests, lists them. Both are left out when empty. A batch with
  no readings and no missed reads is a heartbeat: it is stored as an upload,
  and its answer lists the jobs as any other.
- 422 (`PT422`): the batch does not match the schema, a reading or missed
  read names a register its profile version does not, a stored entry a
  quantity its profile version does not hold in its store, or a latency entry does
  not fit its bucket version or itself (a count per bucket, retries at most the
  answers, `max_ms` in the last bucket counted, a poller started before its
  date ended); the message names the field.
- 503 (`PT503`): a reading, missed read, stored entry or meter-clock read is
  under a profile version, or a
  latency entry under a bucket version, the store has not loaded. The collector keeps the batch and sends it again; load the
  version (`bin/load-profiles`) and it is accepted.
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
with the password PostgREST's `db-uri` uses. Then load the profile catalog
(above).

A new collector, as the owner:

    SELECT admin.create_collector('pilot_01');   -- returns its role, collector_pilot_01

then its token, signed with PostgREST's `jwt-secret`, for the collector's
`ALAVI_SERVER_TOKEN`:

    JWT_SECRET=… bin/collector-token pilot_01 365    # or never

## Dev and tests

Through `bin/dev central …`, with `docker compose up -d timescale postgrest mailpit`:

    bin/dev central bin/test             # the SQL tests, on a fresh minnalavu_test database,
                                         # with contract/profiles loaded
    bin/dev central bin/test-alert       # bin/alert on a fresh minnalavu_alert_test database,
                                         # mailing the mailpit catcher (its mailbox is cleared)
    bin/dev central bin/dev-db --apply   # migrate the dev database PostgREST serves, and load
                                         # contract/profiles into it
