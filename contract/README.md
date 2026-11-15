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
  a profile the collector loaded, a serial that fits its profile) are in its
  description, and in the cases below.
- `tools/`: scripts that compute fixtures independently of any collector.
  `register_decode.py` writes `register-decode.v1.json`
  (`uv run --script contract/tools/register_decode.py`, from the repo root);
  its output must equal the fixture byte for byte.
- `fixtures/`: example messages. Both sides test against them.
  `batch.v1.cases.json` lists changes to the basic batch that the schema must
  reject, and some it must accept; the collector's schema test and the
  server's ingest tests both run every one.
  `config.v1.basic.json` is a polling config, and `config.v1.cases.json`
  changes to it that must be refused, and some that must be accepted, each
  naming the sides that must give that verdict: the schema, the collector's
  parser, and the registry (for a value it stores).
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

A reading or missed read taken for a request carries its `request_id`: one
of the jobs the server's answer to an upload listed (`central/README.md`).
A read the collector made of its own accord carries none; `null` is refused.
A batch with no readings and no missed reads is a heartbeat: a collector
with nothing to send sends one, so its answer lists the pending jobs and
health sees an idle collector, not a silent one.

Values are decimal strings, never JSON numbers, so no float ever carries
energy or money.
