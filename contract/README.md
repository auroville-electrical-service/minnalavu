# Contract

What the collector and the server share. Nothing else is shared between them.

- `schema/batch.v1.schema.json`: a batch of readings, collector → server
  (JSON Schema 2020-12). Version 1 is a draft until the first collector ships.
  After that, any incompatible change is a new version, and the server accepts
  every version still in the field.
- `profiles/*.json`: meter register maps. Each lists its `sources` by ID, and
  each entry and identity check names the one it came from (an entry may
  instead be marked `placeholder`). `verified_on_device` is the date an entry
  was checked against a real meter, or null. A profile's `firmware` section
  says where the meter reports its software and firmware names and the Modbus
  protocol version; they are informational, and never gate a read or label a
  reading. Each profile has an integer `version`: once a batch cites it, that
  version never changes, and a correction is a new version. Each register
  has a `kind` (`cumulative`, `interval`, `demand` or `instantaneous`), and
  its unit and kind belong to the version, not to each reading.
  `meter_clock` says where the meter keeps its own clock and how it counts
  (seconds since `epoch`, local time, no zone). `stored` says what a copy
  reads behind the selector writes, per store (`history`, `snapshot`,
  `load_survey`): the selector by its allowlist name, the count of entries
  held (`available`), each entry's `stamp` (decoded as the meter clock is),
  the support `mask` where the source settles its layout, and the
  quantities: a history's or snapshot's registers, each with its `mask_bit`
  where there is a mask, and the load survey's `interval` (minutes), the
  `values` register its intervals are read from, `per_request` at a time,
  and its `parameters`, by the number the selector takes, which is also the
  parameter's bit in the mask. Each stored quantity has a unit and a kind:
  history and snapshot energies are `cumulative`, load-survey energies
  `interval` (energy in that interval alone), and the store's catalog
  refuses a `cumulative` quantity in the load survey and an `interval` one
  anywhere else, so per-interval energy is never differenced as a meter
  reading. A net figure is never a stored quantity.
- `latency/buckets.v*.json`: the bounds of the request latency histogram's
  buckets, upper bounds in milliseconds, one file per version. A version never
  changes once a batch cites it; a change is a new version in a new file, and
  the old file stays, since collectors in the field go on citing it.
- `config/config.v1.schema.json`: a collector's polling config (JSON Schema
  2020-12), schema version 1: the collector's local file, and the config the
  server will serve, are this one format. The collector takes its fields,
  ranges and patterns from it when it compiles; the registry's checks are
  tested against it. Rules a schema cannot state (each endpoint and serial
  once, each unit id once per endpoint, a backoff's max no less than its min,
  a profile the collector loaded, a serial that fits its profile, a copy
  window whose start and end differ, an interval that divides a day) are in
  its description, and in the cases below. Its `copy_window` is in the
  collector's local wall-clock time, and may cross midnight; each endpoint's
  `copy` says whether its meters' stored entries are copied in it. A meter's
  rounds fall at multiples of its `interval_ms` from local midnight, and
  after a round that gave it no reading it is read again after `retry_ms`,
  unless its next round comes first; a meter may give its own of either.
- `tools/`: scripts that compute fixtures independently of any collector.
  `register_decode.py` writes `register-decode.v1.json`
  (`uv run --script contract/tools/register_decode.py`, from the repo root),
  and `stored_decode.py` (which also refuses a profile whose `stored`
  section breaks the catalog's rules) and `config_digest.py` write
  `stored-decode.v1.json` and `config.v1.digests.json` the same way; each
  one's output must equal its fixture byte for byte, which `bin/check`
  checks (`bin/dev contract bin/check`).
- `fixtures/`: example messages. Both sides test against them.
  `batch.v1.cases.json` lists changes to the basic batch that the schema must
  reject, and some it must accept; the collector's schema test and the
  server's ingest tests both run every one.
  `config.v1.basic.json` is a polling config, and `config.v1.cases.json`
  changes to it that must be refused, and some that must be accepted, each
  naming the sides that must give that verdict: the schema, the collector's
  parser, and the registry (for a value it stores). The server serves
  `config.v1.basic.json` itself to a collector whose registry entries hold
  it (`central/test/collector_config.sql`), so the served document is held
  to the schema and the parser through this fixture.
  `config.v1.digests.json` gives configs, as changes to the basic one, with
  their canonical encoding (RFC 8785) and digest (SHA-256 of its UTF-8 bytes,
  lowercase hex), as the server's answer carries it in `config_digest` and a
  collector reports it in its backlog; its description spells the encoding
  out. Every side that computes a digest must give each.
  `modbus-read-requests.v1.json` gives the exact bytes of sample read
  requests, in both framings, computed independently of any collector, and
  inputs for which no request may be built. Every implementation that talks
  to meters must produce each frame and refuse each input.
  `modbus-read-responses.v1.json` gives the bytes a collector may receive after
  a read, and what it must make of them: the skips (stale frames, noise, bad
  CRCs), then the registers, an exception or an error. Its frames are built
  independently of any collector, too.
  `identity-checks.v1.json` gives, under each profile, what the identity
  check reads, the verdict on what came back (ok, a mismatch, or a failed
  read) and the serial and product code it observed. Every implementation
  that reads meters must give each verdict and observe each value.
  `register-decode.v1.json` gives raw words and the decimal string each must
  decode to, for the profiles' entries and for every data type and word
  order, and words that must decode to no value. Also computed independently
  of any collector. Every implementation that decodes registers must give
  each value and refuse each input; changing a value changes what is billed.
  `stored-decode.v1.json` gives, under each profile, words for the meter
  clock and the stores' stamps with the meter time each must decode to;
  masks with the bits the profile names and those it does not; history and
  snapshot entries as read, with the entries they must give and the
  registers that are unsupported or not finite; and load-survey days, with
  each interval's meter time and value, those not finite and, on the current
  day, those not yet ended by the meter's clock; and words that must give no
  value. Every implementation that copies stored entries must give each.
  `firmware-names.v1.json` gives, under each profile, what is read for the
  names, and words with the text each must decode to or the reason it must be
  refused. Every implementation that reads names must give each.
  `read-round.v1.json` gives one round of an endpoint's meters under a
  retry policy: each request a collector must make (identity first, then
  the registers), with its attempt and the wait before it, what came of it
  (a reply, an exception, a transport failure, or no connection), and the
  readings and missed reads that must result, with their reasons and
  attempts. Every implementation that reads meters must make each request
  and record each event.

A batch says nothing about which collector sent it: the server takes that from
the token the batch is sent with. A batch carries its readings, the reads that
were due and missed (for the health views), the clock status they were
recorded under, and the collector's backlog when it was sent. A reading's
`meter_serial` and `product_code` are what the meter reported in the round it
was read, never what the collector's config says. A missed read carries the
serial read in its round, or null when none could be read.
A batch may also carry `firmware_reads`: a meter's software and firmware
names, each as decoded under its profile's `firmware` section or null when the
meter did not give it, with the serial and product code read in that round.
The collector reads the names in its first round after start, once a day, and
in the round a meter's serial or product code changes; it sends a read only
when the serial, product code or names differ from the last it sent for that
endpoint and unit, and always the first after it starts. A batch with nothing
changed has none. Readings do not carry firmware.

A batch may also carry `clock_checks`: the collector's clock measured against
an NTP server (SNTP), at start, once a day and after its clock steps, each
sent once and kept whether or not the server answered. A check names its
`trigger`, the `server` as configured and its `outcome`; the collector's
send and receive times `t1` and `t4` (microseconds) are always there, and an
answered check adds the server's receive and send times `t2` and `t3`
(nanoseconds), the `address` that answered, `stratum`, `leap` and
`reference_id`. A `kiss_of_death` check has the `address` that sent it and
its `reference_id`, which is the kiss code (`RATE`, `DENY`, `RSTR`), and no
server times, stratum or leap. Any other check has none of those. The times
are stored as measured: offset, delay and error bound are computed in the
store, never sent. Ingest keys a check on (collector, `t1`). `clock` stays
beside it: what the OS claims, where `clock_checks` is what was measured.

A batch may also carry `latency`: each meter's request latency for a UTC
date, as one poller counted it, sent when the date ends by the collector's
clock and when the poller stops. An entry names the meter's `endpoint` and
`unit_id`, the `date`, `poller_started_at` (so a restart's part of a day is
an entry of its own) and the `buckets_version` of `latency/` its answers were
counted under; then `retries` (answers on a retry), `timeouts` (censored,
never timed), `max_ms` (exact, null when nothing answered) and `buckets`, the
answers in each bucket in order, every bucket given: one per bound, and one
for answers above the last. The answers are the sum of `buckets`; the store
refuses an entry whose bucket count is not its version's, whose `max_ms` is
not in its last counted bucket, whose retries outnumber its answers, or
whose poller started after its date ended.
Percentiles are the store's to compute, never sent. Ingest keys an entry on
(collector, endpoint, `unit_id`, `date`, `poller_started_at`).

A batch may also carry `stored_entries`: quantities copied from the entries a
meter stores, one item per quantity per entry. An item names the meter as a
reading does (`endpoint`, `unit_id`, `meter_serial`, `product_code`,
`profile`, `profile_version`), the `store` (`history`, `snapshot` or
`load_survey`), the entry's stamp `meter_time`, the `register_key` in that
store's section of the profile, and its `value`, a decimal string as on a
reading. `meter_time` is the meter's own local time with no zone or offset
(`2026-11-01T00:00:00`), since the meter keeps none; a load-survey item adds
`interval_s`, the interval's length, and its `meter_time` is the interval's
start, and no other item has one. `slot` is the selector value the entry
was read at, evidence only, and `copied_at` the collector's clock when the
reply arrived. A quantity the meter reads as NaN is not sent. Ingest keys
an item on (`meter_serial`, `store`, `register_key`, `meter_time`), never the
slot. A batch may also carry `meter_clock_reads`: the meter's clock
(`meter_time`, decoded under the profile version's `meter_clock`) and the
collector's (`collector_at`), read at the start and end of each copy visit
and once a day per meter. Offsets are the store's to compute.

The backlog may carry `config`: the `digest` of the polling config the
collector is applying, and the `refused_digest` of a served config it refused
since, with the `reason`; both null when it has refused none. A collector that
does not fetch its config sends no `config`.

A reading, missed read or stored entry taken for a request carries its
`request_id`: one of the jobs the server's answer to an upload listed
(`central/README.md`).
A read the collector made of its own accord carries none; `null` is refused.
A batch with no readings and no missed reads is a heartbeat: a collector
with nothing to send sends one, so its answer lists the pending jobs and
health sees an idle collector, not a silent one.

Values are decimal strings, never JSON numbers, so no float ever carries
energy or money.
