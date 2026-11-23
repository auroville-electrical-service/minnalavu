# Operating a collector host

Placeholders (`<pc>`, `<root>`, `<src>`, `<store>`) are in `SKILL.md`.

## Running commands

The host's SSH shell eats `$` and nested quotes. Send PowerShell through
`pcps`, beside this file, which encodes the script:

    skills/minnalavu-ops/pcps <pc> <<'EOF'
    Get-Service alavi_alavi
    EOF

Copy files with `scp '<pc>:C:/alavi/log/alavi.log' data/…` (forward slashes).
What comes off the host goes into the gitignored `data/`.

## What lives where

Under `<root>`:

- `settings.json`: `server.url`, `server.token`, and the paths below.
- `buffer\`: unacknowledged batches; `buffer\control` is where `stop.ps1`
  asks for a quiesce.
- `log\alavi.log`, rotated to `.0`, `.1` at `log.max_file_bytes`;
  `log\status.json`, rewritten as the collector runs. Its `buffer.backlog`
  (batches, bytes, `refused`, `quarantined`, `discarded_files`) and `uplink`
  (last result, next attempt) are the first things to read; `settings` lists
  every setting but the token, which it never shows.

The scripts are in `<src>\alavi\rel\windows\`, not in `<root>`. The service is
`alavi_alavi`.

## Changing settings.json

Read it with `ConvertFrom-Json`, but never write it back with Windows
PowerShell 5's `ConvertTo-Json`: it truncates nesting past depth 2, and
`Set-Content -Encoding UTF8` adds a byte-order mark. Replace the value in the
raw text instead, after checking it occurs exactly once, keep a dated copy,
and write without a BOM:

    $raw = [IO.File]::ReadAllText($f)
    Copy-Item $f "$f.pre-<what>-<date>"
    [IO.File]::WriteAllText($f, $raw.Replace($old, $new), (New-Object Text.UTF8Encoding($false)))

Read it back with `ConvertFrom-Json`. A token goes to the host as a file
(`scp`, read, delete), never on a command line, and is never printed: show
its length and whether it matches.

## Stopping and starting

Only through `stop.ps1`, which asks the collector to quiesce at a round
boundary, then stops the service. Dry run first:

    & powershell -NoProfile -ExecutionPolicy Bypass -File <src>\alavi\rel\windows\stop.ps1 -Root <root>
    & powershell -NoProfile -ExecutionPolicy Bypass -File <src>\alavi\rel\windows\stop.ps1 -Root <root> -Apply
    Start-Service alavi_alavi

Settings are read at start, so a settings change takes effect only after
this. Upgrades go through `upgrade.ps1` beside it, which does the same stop.

## A store the host cannot reach

A store on the Mac is reached through a reverse tunnel to the dev TLS front:

    docker compose up -d postgrest && docker compose --profile uplink up -d uplink
    ssh -o ExitOnForwardFailure=yes -N -R 9443:127.0.0.1:9443 <pc>

with `server.url` `https://localhost:9443/`. Stopping `postgrest` and
`uplink` is a freeze: the collector buffers, as offline.

## Minting the host's token on a shared server

`central/bin/collector-token` hands the JWT secret to `openssl` as an
argument, which any user of the machine can see in the process list. On a
server shared with another project, sign it in a process that reads the
secret itself, with the same header and claims (`{"role":"collector_<id>"}`,
plus `exp` unless it never expires), and test it against `<store>`'s
`/rpc/collector_config` (200 with it, 401 without) before it goes to the host.

## After a change

Check from both ends: `status.json`'s `uplink.result` is `stored` and the
backlog falls; the store's `store.uploads` and `health.collectors` show the
collector. The host's clock may differ from the store's: compare times
across the two only through the clock checks.
