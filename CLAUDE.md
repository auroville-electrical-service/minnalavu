# Minnalavu

Open-source meter reading for Auroville Electrical Service (AVES). On-site
collectors poll ~500 (soon ~1,500) Secure Elite meters over read-only Modbus on
RS-485 daisy chains, buffer readings for weeks if offline, and forward them to a
central TimescaleDB store. Minnalavu measures and stops there: what each meter
read, when, and from which collector. Accounts, the meter hierarchy, tariffs,
rating, statements, the Tally export and the user portal belong to a separate
project, `minkanakku`, which reads the store through a read-only role and never
writes to it.

| Name | Tamil | Meaning | Role |
|---|---|---|---|
| `minnalavu` | மின்னளவு | electricity measure | The project and the central store |
| `alavi` | அளவி | meter / measurer | On-site collector |
| `minkanakku` | மின்கணக்கு | electricity account | Separate project: accounts, rating and billing |

## Layout

Sibling Mix projects (poncho, no umbrella), the central store, and the shared contract:

- `alavi/`: collector, a plain OTP app that must also run on Windows:
  no NIFs, nothing Linux-only. Nerves firmware, later, is a separate `alavi_firmware/`.
- `central/`: the central store (`minnalavu`): SQL migrations for PostgreSQL +
  TimescaleDB, behind PostgREST; SQL tests, above all of the grants.
- `kai_alavi/`: the handheld collector's TypeScript library (bun, Biome,
  `tsc`): no I/O; read requests and replies, the identity check, decode and
  batches, to the same contract fixtures as `alavi`.
- `contract/`: batch schema, meter register profiles, shared fixtures.
- `simulator/`: Modbus endpoint simulator with faults; a test dependency of `alavi`.

## Commands

Everything runs in the dev container (OrbStack): `bin/dev <project> <cmd>`.

```sh
bin/dev alavi mix test                 # or simulator
bin/dev alavi mix check                # format, warnings, credo --strict, dialyzer, test
bin/dev simulator mix check
bin/dev kai_alavi bun install          # once, and after a dependency change
bin/dev kai_alavi bun run check        # Biome, tsc, tests
bin/dev simulator mix simulator.run --port 5020 --framing tcp --meter 1:elite_440 --meter 3:elite_500

docker compose up -d timescale postgrest mailpit   # the central store, for those below
bin/dev central bin/test               # SQL tests, on a fresh test database
bin/dev central bin/test-alert         # the alert job, against the mailpit mail catcher
bin/dev central bin/dev-db --apply     # migrate the dev database PostgREST serves, then:
bin/dev alavi mix test --only e2e      # simulator -> collector -> PostgREST -> database
bin/dev . shellcheck bin/dev central/bin/*       # shell scripts; and:
bin/dev . shfmt -d -i 2 -ci bin central/bin
```

Checks must be clean before every commit: `mix check` (which leaves out the
end-to-end test), `bun run check`, `bin/test`, and for a change to a script, `bin/test-alert`,
ShellCheck and shfmt; the end-to-end test too for a change to the uplink, the
contract or `central/`.

## Hard rules

- **Read-only Modbus, with one named exception.** Function codes 03/04 only,
  except `Alavi.Modbus.Selector`: one selector register per write (which
  stored history, snapshot or load-survey entry a meter shows), only from its
  allowlist, with its model's function code and a value in range, sent only
  through `Alavi.Selectors.Session`, which saves the values to put back first.
  Never write anything else to a meter.
- **Never expose Modbus (port 502) to the internet.** Collectors only make outbound connections.
- **Deployment data never enters git:** it lives in the gitignored `data/` and the database, not in code, fixtures or commit messages.
- **Collect cumulative energy registers**, the ones billing takes end − start readings from. Never offer integrated instantaneous power as energy.
- **Import and export are separate quantities everywhere.** Never store or compute only a net figure.
- **Energy uses `Decimal`**, never floats. Convert register values to Decimal at ingestion with an explicit, documented precision.
- **Raw readings are immutable.** Corrections, estimates and meter swaps are separate records that reference the raw data.
- **Ingestion is idempotent.** The key is (meter_id, register, timestamp); resent batches must not double-count. Late batches (weeks old) must be accepted, and findable by when they arrived, so that rating can re-rate any open period.
- **Everything time-varying has effective dates:** endpoints, meter installations, CT/PT ratios.
- **Nothing about accounts or people is stored here.** Meters are identified by what a collector can observe (endpoint, unit ID, model, serial, product code); mapping them to accounts is `minkanakku`'s job.
- **Do not guess register addresses.** Every register map entry names its `source`, an ID whose provenance (document, version, section) is recorded outside the repo, and carries `verified_on_device`: the date it was checked against a real meter, or null. Provenance itself is never committed.
  - Record word order, scaling, data type, and holding vs. input register for each entry.
- **A change to a register profile, a decode or a unit alters what consumers are charged:** it sets the energy every charge is computed from. Write and test such changes, and flag them clearly (at the top of the PR description, when there is one).
- **Collector timestamps:** collectors may be offline for long periods, so keep clocks synced (NTP when online, RTC hardware otherwise) and record clock source/quality per batch.

## Conventions

- Register maps live in `contract/profiles/`; each entry names its source
  ID, or is marked `placeholder: true`.
- Energy is `Decimal` end to end; on the wire, decimal strings.
- The read-only role for `minkanakku` (not built yet) will be an interface:
  change it with the same care as the collector contract.
- Commit messages say what the code does, subject only: no sign-off or
  process notes (those go in the PR description), and nothing about the
  deployment. The repo's history is public.
- Keep this file short: what every session needs, nothing more.
