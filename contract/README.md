# Contract

What the collector and the server share. Nothing else is shared between them.

- `schema/batch.v1.schema.json`: a batch of readings, collector → server
  (JSON Schema 2020-12). Version 1 is a draft until the first collector ships.
  After that, any incompatible change is a new version, and the server accepts
  every version still in the field.
- `profiles/*.json`: meter register maps. Each lists its `sources` by ID, and
  each entry and identity check names the one it came from (an entry may
  instead be marked `placeholder`). `verified_on_device` is the date an entry
  was checked against a real meter, or null.
- `fixtures/`: example messages. Both sides test against them; a fixture's raw
  words must decode to its stated value under its profile.
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

A batch says nothing about which collector sent it: the server takes that from
the token the batch is sent with. A batch carries its readings, the reads that
were due and missed (for the health views), the clock status they were
recorded under, and the collector's backlog when it was sent. A reading's
`meter_serial` and `product_code` are what the meter reported in the round it
was read, never what the collector's config says. A missed read carries the
serial read in its round, or null when none could be read.

Values are decimal strings, never JSON numbers, so no float ever carries
energy or money.
