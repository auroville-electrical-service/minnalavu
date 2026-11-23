# Moving the store

A polled reading cannot be read again. A reading the old store accepted
after the backup is in neither the new store nor the collector's buffer,
because the buffer drops what the store has accepted. So the order matters:
**freeze, back up, restore, repoint, fill** (`central/README.md`
*Copy fills*).

This file is the procedure. Where the stores run, and how to reach them, is
the deployment's own business, and none of it goes in this repo.

Every step that changes something needs the owner's go-ahead. A store with
real readings is not a test database.

## 1. Freeze

If a collector holds a backlog and its route to the old store is known to
work, drain it there first: the backlog is then in the dump and in the
comparison, and the repoint starts from an empty buffer.

Stop the old store's PostgREST, and any TLS front before it. A collector that cannot upload buffers its
batches, as it does offline, and loses nothing. Its buffer has a limit
(`buffer.max_bytes`), so keep the freeze shorter than that allows.

Then check that the freeze has taken: no upload in `store.uploads` after the
stop, for every collector.

    SELECT collector_id, max(received_at) FROM store.uploads GROUP BY collector_id;

## 2. Back up

Run the dump with the server's own `pg_dump`, inside its container. The dev
container's client is older than the server, and `pg_dump` refuses that.

    pg_dump -U postgres -Fc -d minnalavu -f minnalavu.dump

Roles belong to the cluster, not to the database, so the dump does not carry
them. For a new cluster of its own, dump them too:

    pg_dumpall -U postgres --roles-only -f roles.sql

**Not for a cluster another project shares.** That file carries every role,
test ones included, and sets the shared roles' passwords (`authenticator`'s
among them) to the old cluster's. Instead, list the roles the database's
grants and owners name, check each exists on the target, and make each
collector's role there as `admin.create_collector` does, without its row
(the restore brings the rows):

    CREATE ROLE collector_<id> NOLOGIN;
    GRANT collector TO collector_<id> WITH INHERIT TRUE, SET FALSE;
    GRANT collector_<id> TO authenticator WITH INHERIT FALSE, SET TRUE;

Database-level grants (`pg_database.datacl`) are not in a dump made
without `--create` either: compare them on both sides.

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

If the target database already exists, drop it first (`WITH (FORCE)`
cuts its readers off until the restore ends). Then reload PostgREST's
schema cache.

Compare the two stores before going on: `counts.sql`, beside this file, on
both, and diff. It counts every table and gives the last migration,
`health.problems`, `admin.copy_holes(since => '2000-01-01')` and the last
upload. Every figure should match. Compare the grants on the store's
tables and functions too (a hash of `relacl` and `proacl` on each side),
and check that an UPDATE of a reading is refused in the new store.

## 4. Repoint

- **PostgREST** on the new store. If it has the same JWT secret, the
  collectors' tokens still work. A new secret needs a new token for each
  collector (`central/bin/collector-token`; on a shared server, see
  `collector-host.md`).
- **Collectors:** `server.url`, and `server.token` if it changed, in each
  collector's `settings.json`, then restart its service
  (`collector-host.md`). The collector then uploads its buffer to the new
  store.
- **Readers:** whatever reads the store through its read-only role now
  points at the new one.

Then check the new store: `health.collectors` shows an upload after the
restart, and the backlog drains.

## 5. Fill

After the move is complete, not during it: a fill needs the collector
uploading to the new store.

Copy progress lives on the collector, so a complete restore of a store
frozen before its dump leaves no holes, and copies resume. Then judge the
holes first (`copy-holes.md`) and fill only what that finds.

Fill everything when the old store's completeness is in doubt (a freeze not
confirmed, a restore from an older backup) or the new store is empty: one
`admin.request_fill` per collector, covering every copied meter and store,
ranged from the oldest entry its meters can still hold to a day past now,
in the meters' clock. After a move to an empty store, it is the only way
back to the stored entries.

A collector that cannot run fill jobs leaves the request to expire (see
`copy-holes.md`). Then the freeze is all that protected the move, and the
report says so.

## 6. Keep the old store

Leave the old store and the dump in place until the new store has taken
uploads from every collector and its holes are judged. Deleting either one
is the owner's call.
