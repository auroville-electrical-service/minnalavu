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
- `tools/`: scripts that compute fixtures independently of any collector.
  `register_decode.py` writes `register-decode.v1.json`
  (`uv run --script contract/tools/register_decode.py`, from the repo root);
  its output must equal the fixture byte for byte.
- `fixtures/`: example messages. Both sides test against them.
  `batch.v1.cases.json` lists changes to the basic batch that the schema must
  reject, and some it must accept; the collector's schema test and the
  server's ingest tests both run every one.
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

A reading or missed read taken for a request carries its `request_id`: one
of the jobs the server's answer to an upload listed (`central/README.md`).
A read the collector made of its own accord carries none; `null` is refused.
A batch with no readings and no missed reads is a heartbeat: a collector
with nothing to send sends one, so its answer lists the pending jobs and
health sees an idle collector, not a silent one.

Values are decimal strings, never JSON numbers, so no float ever carries
energy or money.
