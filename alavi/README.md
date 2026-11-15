# alavi (அளவி)

On-site meter collector. Polls Secure Elite meters over read-only Modbus
(TCP or RTU over TCP; the one write is an allowlisted selector register,
`Alavi.Modbus.Selector`), keeps every reading in a disk buffer, and sends the
buffered batches over HTTPS to the central server, deleting each only once the
server has stored it. A plain OTP app: runs on Windows, Linux, macOS, and later
on Nerves hardware.

Tests run against `../simulator`: `bin/dev alavi mix check` from the repo root.

## Settings

A release reads all its settings from one file, `settings.json` in the release
root (the directory holding `bin/`), and from nowhere else; see
`Alavi.Settings` for every key. Every key is required, unknown keys are
rejected, and an invalid file stops startup with an error naming the key.
`settings.example.json`, beside it in the release, has every key with invented
values; copy it to `settings.json` and fill it in. In JSON a Windows path's
backslashes are doubled (`"C:\\alavi\\buffer"`), or written as `/`.

**The file holds the collector's token**, which is its identity to the
server. Restrict its ACL (or mode) so that only the account the service runs
as, and administrators, can read it (on Windows, step 1 below). A new
release does not bring a `settings.json`: copy the old one into the new
release root, and restrict the copy too.

A batch the server rejects for good is moved to `<buffer dir>/quarantine/`
with the server's reason beside it, and never deleted; see `Alavi.Uplink.Response`
for which answers count as that.

The polling config the server serves is fetched whenever an answer names a
digest other than the collector's, and once it parses against the loaded
profiles it is saved as `<buffer dir>/config/served.json`
(`Alavi.Config.Saved`); the collector starts from that file whenever there is
one, and from `polling_config` only before the first. A config saved is applied
without a restart: endpoints unchanged by host, port and settings poll on, new
ones start, and a changed or dropped one stops at the end of the round under
way (`Alavi.Pollers.Applier`); a dropped one with selectors owed puts them back
first. One that does not parse
is refused: the collector keeps its config, logs why, and reports the refusal
in each batch until the server serves another. The status page shows both
digests.

Selector values to put back are kept in `<buffer dir>/selectors/`
(`Alavi.Selectors.Store`). A `.restore` file there is a restore owed: the
endpoint shows as faulted until the collector has put the selectors back and
read them back. Never delete one by hand unless the meter's selectors have been
checked and set right some other way.

## Windows service

From the release root, in an administrator's command prompt:

1. Copy `settings.example.json` to `settings.json` and fill it in (or copy
   the old release's). Then leave only Administrators and SYSTEM, the
   service's account, with access to it (SIDs, so the display language does
   not matter):
   `icacls settings.json /inheritance:r /grant "*S-1-5-32-544:F" /grant "*S-1-5-18:F"`.
   `icacls settings.json` should then list only `BUILTIN\Administrators:(F)`
   and `NT AUTHORITY\SYSTEM:(F)`. Restrict the release root the same way, as
   the service runs there and a crash dump it writes there (`erl_crash.dump`)
   can hold the token:
   `icacls . /inheritance:r /grant "*S-1-5-32-544:(OI)(CI)F" /grant "*S-1-5-18:(OI)(CI)F"`.
   Not with `/T`: that strips each file's inherited entries and leaves
   files with none, so nothing can run `erlsrv.exe`. If it happened,
   `icacls * /reset /T` makes every file inherit the root's again.
2. With no service running, check the settings: `bin\alavi.bat start` runs the
   collector in the console, and a settings error is printed there. Stop it
   with Ctrl+C.
3. `bin\alavi.bat install` adds the service `alavi_alavi` (LocalSystem,
   automatic start), and prints the path of its `erlsrv.exe`, written
   `erlsrv` below.
4. `erlsrv start alavi_alavi`.

`erlsrv list alavi_alavi` should show `OnFail: restart`, the release root as
`WorkDir:` and `alavi_alavi` as `InternalServiceName:`: the release's
`bin\alavi.bat` installs the service with `-onfail restart -workdir
-internalservicename` (`mix.exs`), so erlsrv restarts a node that stops on its
own, a node that halts writes its `erl_crash.dump` in the release root, and the
service starts at boot (under a generated internal name it does not). A service
installed without these must be removed (`erlsrv remove alavi_alavi`) and
installed again from step 3. A node that stops again within 10 seconds of
being restarted, as one does with an invalid settings file, is left stopped
rather than restarted in a loop: fix the cause (the log, or step 2) and start
it again. To install a new release, `erlsrv remove alavi_alavi`, then the
steps above from the new release root.

## Logs

A release logs to `alavi.log` in the settings' `log.dir`, rotated at
`log.max_file_bytes` with `log.max_files` older files kept (`alavi.log.0` is
the newest of them), timestamps in UTC. Process crashes are logged with their
reason, stacktrace, last message and state; the collector's token is never
shown in them. An invalid settings file stops startup before the log file is
known, so that error goes to standard output (on Windows, see erlsrv's
`-debugtype`). Dev and test log to the console.

When an endpoint sends bytes that are not a usable reply (noise, a bad CRC, a
stale transaction id, a reply that does not parse), they are logged in hex
with the endpoint and unit, so a misbehaving device can be diagnosed from the
log alone. `raw_bytes_log` in the settings caps this per endpoint: bytes shown
per line, and lines per window, then one line counting what was suppressed.

A meter's identity (product code, serial, energy unit setting) is read every
round, before its registers. Readings carry the serial and product code read.
A serial in the polling config is optional and only an expectation: a
different one read is logged as a warning, and the readings still go under
the serial read. A meter whose identity read fails, or whose serial is empty
or not printable, gives missed reads for that round, with no serial if none
was read.

A meter's software and firmware names and Modbus protocol version (its
profile's `firmware` section) are read after every meter's readings in the
round are recorded: in the first round after start, when the last names read is
a day old, and in the round its serial or product code differs from the last
round's. They go to the
server only when they, or the serial or product code read with them, differ
from the last sent for that endpoint and unit, and always the first after
start. A name the meter does not give (blank, not printable, or exception 02,
no such register) is sent as null; any other refusal fails the names read. A
names read that fails is logged and tried again the next round; it is never a
missed read, and readings never wait on it.

## Clock

On Windows each batch's clock status comes from the Windows Time service:
`w32tm /query /status /verbose`, run every `clock.refresh_ms` and cached. An
NTP peer is `ntp`, the local CMOS clock `rtc`, and a free-running clock, a
failure, or output not recognised is `unsynced`, logged once as a warning with
the raw output. Only English output is recognised: the labels change with the
display language. Elsewhere the status is always `unsynced`.

That is what the OS claims. What the clock *is* gets measured: the collector
sends one SNTP query to each of `clock.ntp_servers` in turn (UDP port 123,
outbound only), stopping at the first that answers, at start, every 24 h of
monotonic time, and after the clock steps (the OS clock and monotonic time
disagreeing by more than 2 s across a 60 s watch; at most one such check per
10 min). Each query, answered or not (timed out, unreachable, kiss-o'-death,
invalid), goes to the server in the batch's `clock_checks` with its four
times as measured; offsets are the store's to compute. An empty
`clock.ntp_servers` turns the checks off. The status page shows the last
check and the offset it implies, for display only.

## Status

What the collector is doing is kept in memory and written, every few seconds
when it has changed, to `status.json` in `log.dir`, beside the log: per
endpoint its last rounds and failures, per meter the serial and product code
read, its firmware names as last read and its register values as read, the
raw-bytes lines, the buffer's backlog, the uplink's last and next attempt, the
clock, the release version and the settings (never the token). It is replaced whole (a temporary file renamed
over it), and the recent history in it is lost on restart: the log and the
buffer are the record. Settings files of `schema_version` 1 or 2 are refused,
saying what to add: version 2 added `status`, version 3 `clock.ntp_servers`.

The same is shown as a page, on the collector's own PC only: open
`http://127.0.0.1:8502/` (or `http://localhost:8502/`; the port is
`status.port` in the settings) in a browser there. It refreshes itself every
few seconds; `/status.json` is the same data as the file. The page is a
summary, kept small however many meters there are: the clock and its last
check, uplink, buffer
backlog (refused, discarded or quarantined batches marked), version and start
time; endpoints and meters counted by the state of their last round; in full,
only what is not OK (each endpoint down, or with units that missed or read
partly, or a serial that is not the one expected, with the reasons); links to
the endpoints that are OK; then the raw-bytes lines and the settings. Each
endpoint has its own page, `/endpoint/<n>` for the `n`th endpoint of the
polling config, linked from the summary: its framing, last rounds per unit ID
and recent failures, and per meter the serial expected and read (a mismatch is
marked), the product code, the firmware names, the register values as read and
the missed reads.

What it does not do: it never acts. There is no control on it: no settings
editing, no "poll now", no register read; any method but GET (and HEAD) is
refused. It listens on 127.0.0.1 only, set in the code: no setting makes it
reachable from the network, and a request whose `Host` is not
`127.0.0.1:<port>` or `localhost:<port>` is refused, so another web page the
browser opens cannot read it. It never shows the token. It shows register
values as read, never consumption or cost, and keeps nothing beyond the recent
history in memory. If `status.port` is already in use, the error is logged and
the collector runs on without the page; `status.json` is still written.

## No other listening ports

A collector only connects outwards; its one listener is the status page, on
127.0.0.1 (above). Its release runs with Erlang distribution off (`rel/env.sh.eex`, `rel/env.bat.eex`) and starts no epmd.
The Windows service is the exception: erlsrv always runs a named node, so
`rel/vm.args.eex` adds `-dist_listen false -start_epmd false`, which keep any
node from listening or starting epmd.

So `bin/alavi remote`, `rpc`, `stop`, `restart` and `pid` do not work: they
need distribution. Stop a collector with its service manager (or SIGTERM on
Linux and macOS). To see what a running collector is doing, read its log file,
and the server's health views for what has reached the server.
