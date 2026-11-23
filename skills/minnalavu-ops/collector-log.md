# Reading a collector's log

The log says what went wrong; `status.json` says what went right, since the
poller does not log a successful read. Read both, and judge a warning only
against what the status says about the same unit.

Placeholders are in `SKILL.md`; reaching the host is `collector-host.md`.

## 1. Fetch

The service writes `log\alavi.log` under `<root>`, rotated at
`log.max_file_bytes` to `alavi.log.0` and `.1`, with `status.json` beside
it. Copy them into the gitignored `data/`, one folder per visit:

    d=data/pc-run-$(date +%Y%m%d); mkdir -p "$d"
    skills/minnalavu-ops/pcps <pc> <<<'Get-ChildItem C:\alavi\log | Format-Table Name,Length,LastWriteTime'
    scp -q '<pc>:C:/alavi/log/alavi.log' '<pc>:C:/alavi/log/status.json' "$d/"

Fetch a rotation too when the current file starts after the time you need.
Log times are UTC.

## 2. Group

A crash or boot report spans several lines. Join each entry onto one line,
then count levels and group the rest by shape, with addresses and numbers
masked:

    cd "$d"
    awk '/^20[0-9][0-9]-[0-9][0-9]-[0-9][0-9] /{if(e)print e; e=$0; next}{e=e" ⏎ "$0}END{print e}' alavi.log > entries.txt
    awk '{print $3}' entries.txt | sort | uniq -c
    awk '$3!="[info]"' entries.txt | cut -d' ' -f3- | cut -c1-110 \
      | sed -E 's/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(:[0-9]+)?/ADDR/g; s/[0-9]+/N/g' \
      | sort | uniq -c | sort -rn | head -40

Any `[error]` is a finding. Each `[debug]` pair (`ssl_handler`,
`inet_gethost_native_sup`) is one start: match the starts against the
installs and restarts you know of.

## 3. Set aside what is known

These are the collector handling the network as designed. They need a
finding only if their pattern changes:

| Shape | Means |
|---|---|
| `cannot connect to …: {:socket, :timeout}` / `:econnrefused` | endpoint down or unpowered |
| `copy … endpoint not reached, copied again in …` | the same, seen by the copier |
| `uplink: batch … not sent … :econnrefused` | no route to the store (no tunnel, store frozen) |
| `bytes skipped before the reply (stale transaction id)` | a late reply to an abandoned request, discarded |
| `selector restore failed (attempt N) … :unreachable`, then `selectors restored and read back; nothing owed` | a put-back owed while the endpoint was down, settled when it returned. A restore that never settles is a finding. |

## 4. Cross-check what is left

Find each remaining warning's unit in `status.json` before calling it a
fault:

    jq -r '.endpoints[] | .host as $h | .meters[] | "\($h) \(.unit_id) \(.last_read_at)"' status.json

- **A unit with no `last_read_at` has never answered a poll.** Its copy
  failing (`{:identity, {:exception, 11}}`, the gateway reporting no reply
  from the meter) is the same silence, not a copy fault.
- **A unit that reads in polls but fails its copy** is the interesting one.
  Count its failures and their times: one failure among clean nights is a
  gateway hiccup; the same read failing every night is a finding.
- **`reply rejected (…)` lines carry the reply's bytes.** Compare its length
  with what was asked for (function, byte count, data). Extra bytes after the
  data, or a byte count that differs from the request, is a gateway or
  framing pattern; note which endpoints show it.

Also read the top of `status.json`: `buffer.backlog` (`refused`,
`quarantined`, `discarded_files` all 0; `bytes` against `max_bytes`), and
`uplink` (last result and next attempt).

A meter's `next_due_at` is in the collector's local time with its offset
(`+05:30`), as its poll slots are; `last_read_at` and `as_of` are UTC
(`Z`). Both are exact instants, so compare them parsed, not as text.

## 5. Report

Per finding: the shape, how many times, which endpoints and units, the first
and last time, what `status.json` says of the same units, and whether it
points at a code fix or at the site. Addresses and unit IDs are deployment
data: they go in `_notes/` or `data/`, never in a commit or an issue.
