---
name: minnalavu-ops
description: Operating minnalavu's deployment — its collector hosts and its central store. Load before any command against a collector host (reaching it, its settings, stopping or upgrading it, a tunnel), when reading a collector's log or status, before moving, restoring or rebuilding a store that holds real readings, and when checking or filling the holes in the copied stores (after a store move or restore, discarded or quarantined buffer segments, or a meter clock step). An index: it says which page to read.
---

# Operating minnalavu

Read the page for the situation; each page is the procedure. Commands
against the box that runs the store (deploys, migrations, its database
server) are the `aves-box` skill.

| Situation | Read |
|---|---|
| Any command on a collector host: reaching it, its files, `settings.json`, stop/start, a tunnel to a dev store, minting its token | `collector-host.md` |
| What has the collector been doing; a site visit; after an upgrade | `collector-log.md` |
| Moving, restoring or rebuilding a store with real readings | `store-move.md`, then `copy-holes.md` |
| Holes in the copied stores; after discarded or quarantined segments; a meter clock step | `copy-holes.md` |

Common chains: a visit is `collector-host.md` then `collector-log.md`; a
store move uses `collector-host.md` for the drain and the repoint.

Beside the pages: `pcps` (PowerShell on a host), `counts.sql` (a store
move's comparison), `holes.sql` (copy holes).

## Placeholders

The pages are public, so a deployment's values are in its private notes,
not here:

| Placeholder | What it is |
|---|---|
| `<pc>` | SSH alias of a collector host |
| `<root>` | its install directory, `C:\alavi` by the scripts' default |
| `<src>` | its checkout of this repo, which holds `alavi\rel\windows\` |
| `<store>` | the store's ingest URL its collector uploads to |

Addresses, unit IDs, tokens and host names found while working go in the
private notes or `data/`, never in a page, a commit or an issue.
