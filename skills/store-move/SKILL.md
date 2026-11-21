---
name: store-move
description: Move minnalavu's central store to another database or server (dev to a VPS, dev to prod, a rebuild from backup) without losing a reading. Covers freezing the collectors' uploads, dumping and restoring a TimescaleDB database with its roles, repointing PostgREST and the collectors, the fill that follows, and checking the result. Load before moving, restoring or rebuilding a store that holds real readings.
---

# Moving the store

A polled reading cannot be read again. A reading the old store accepted
after the backup is in neither the new store nor the collector's buffer,
because the buffer drops what the store has accepted. So the order matters:
**freeze, back up, restore, repoint, fill** (ADR 0025,
`central/README.md` *Copy fills*).

This file is the procedure. Where the stores run, and how to reach them, is
the deployment's own business, and none of it goes in this repo.

Every step that changes something needs the owner's go-ahead. A store with
real readings is not a test database.

## 1. Freeze

Stop the old store's PostgREST. A collector that cannot upload buffers its
batches, as it does offline, and loses nothing. Its buffer has a limit
(`backlog_max_bytes`), so keep the freeze shorter than that allows.

Then check that the freeze has taken: no upload in `store.uploads` after the
stop, for every collector.

    SELECT collector_id, max(received_at) FROM store.uploads GROUP BY collector_id;

## 2. Back up

Run the dump with the server's own `pg_dump`, inside its container. The dev
container's client is older than the server, and `pg_dump` refuses that.

    pg_dump -U postgres -Fc -d minnalavu -f minnalavu.dump

For a new cluster, also dump the roles: collector roles, `authenticator`,
and the read-only roles. Roles belong to the cluster, not to the database,
so the database dump does not carry them.

    pg_dumpall -U postgres --roles-only -f roles.sql

`pg_dump` warns about circular foreign keys in TimescaleDB's own catalog.
That warning is about data-only dumps. A full dump restores cleanly.

## 3. Restore

On the new server, at the same TimescaleDB version:

    psql -U postgres -f roles.sql                    # a new cluster only
    psql -U postgres -c 'CREATE DATABASE minnalavu'
    psql -U postgres -d minnalavu -c 'CREATE EXTENSION IF NOT EXISTS timescaledb' \
      -c 'SELECT timescaledb_pre_restore()'
    pg_restore -U postgres -d minnalavu minnalavu.dump
    psql -U postgres -d minnalavu -c 'SELECT timescaledb_post_restore()'

Keep the owners: no `--no-owner`. Grants are the store's interface.
`refuse_change` refuses UPDATE, DELETE and TRUNCATE, not INSERT, and the
restore creates triggers only after the data, so nothing needs disabling.

Compare the two stores before going on. Count readings, missed reads,
stored entries, batches, uploads, clock checks, collectors and requests,
and check `schema_migrations`, `health.problems` and
`admin.copy_holes(since => '2000-01-01')`. Every figure should match. Then
check that an UPDATE of a reading is refused in the new store.

## 4. Repoint

- **PostgREST** on the new store. If it has the same JWT secret, the
  collectors' tokens still work. A new secret needs a new token for each
  collector (`central/bin/collector-token`).
- **Collectors:** `server.url`, and `server.token` if it changed, in each
  collector's `settings.json`, then restart its service. The collector then
  uploads its buffer to the new store.
- **Readers:** whatever reads the store through its read-only role now
  points at the new one.

Then check the new store: `health.collectors` shows an upload after the
restart, and the backlog drains.

## 5. Fill

Make one `admin.request_fill` per collector, covering every copied meter and
store. Range it from the oldest entry its meters can still hold to a day
past now, in the meters' clock. This catches whatever the old store lacked.
After a move to an empty store, it is the only way back to the stored
entries.

A collector that cannot run fill jobs leaves the request to expire (see
`copy-holes`). Then the freeze is all that protected the move, and the
report says so.

When the fills are answered, judge whatever is left with the `copy-holes`
skill.

## 6. Keep the old store

Leave the old store and the dump in place until the new store has taken
uploads from every collector and its holes are judged. Deleting either one
is the owner's call.
