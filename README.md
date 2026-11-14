# Minnalavu (மின்னளவு)

Open-source meter reading for Auroville Electrical Service (AVES).
"Minnalavu" means "electricity measure" in Tamil. It collects and stores what
each meter read. Accounts, rating and billing are a separate project that reads
the store.

- **`alavi/`**: the on-site collector. Polls Secure Elite meters over Modbus
  (read-only, but for one allowlisted selector write that chooses which
  stored entry a meter shows), buffers readings on local disk, forwards them to the server.
- **`contract/`**: the versioned collector ↔ server message schema, meter
  register profiles and shared fixtures.
- **`kai_alavi/`** (கை அளவி, "hand meter"): a TypeScript library with no I/O
  for a handheld collector app: read-only Modbus requests and replies, the
  identity check, register decode and batches, tested against the same
  contract fixtures as `alavi`.
- **`simulator/`**: a Modbus simulator serving Elite register maps on
  daisy-chained unit ids, with fault injection.

## Status

Phase 1 (collection) has started: a read-only Modbus TCP / RTU-over-TCP
collector with a disk buffer and an HTTPS uplink, and a TimescaleDB store
behind PostgREST (`central/`). Every register profile entry is sourced, but
none is yet verified on a meter.

## Development

Everything runs in containers ([OrbStack](https://orbstack.dev) or Docker):

```sh
bin/dev alavi mix test    # any command, in any project folder
bin/dev alavi mix check   # format, warnings, Credo, Dialyzer, tests
```

## Licence

[0BSD](LICENSE). No attribution required. Contributions are accepted under the
same licence; no CLA.
