# alavi (அளவி)

On-site meter collector. Polls Secure Elite meters over read-only Modbus
(TCP or RTU over TCP), keeps every reading in a disk buffer, and sends the
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
as, and administrators, can read it. A new release does not bring a
`settings.json`: copy the old one into the new release root.

A batch the server rejects for good is moved to `<buffer dir>/quarantine/`
with the server's reason beside it, and never deleted; see `Alavi.Uplink.Response`
for which answers count as that.

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

## Status

What the collector is doing is kept in memory and written, every few seconds
when it has changed, to `status.json` in `log.dir`, beside the log: per
endpoint its last rounds and failures, per meter the serial and product code
read, its firmware names as last read and its register values as read, the
raw-bytes lines, the buffer's backlog, the uplink's last and next attempt, the
clock, the release version and the settings (never the token). It is replaced whole (a temporary file renamed
over it), and the recent history in it is lost on restart: the log and the
buffer are the record. Settings `schema_version` 1 files are refused: version 2
added `status`.

The same is shown as a page, on the collector's own PC only: open
`http://127.0.0.1:8502/` (or `http://localhost:8502/`; the port is
`status.port` in the settings) in a browser there. It refreshes itself every
few seconds; `/status.json` is the same data as the file. It shows the clock,
uplink, buffer backlog, version and start time, then per endpoint its framing,
last rounds per unit ID and recent failures, per meter the serial expected and
read (a mismatch is marked), the product code, the firmware names, the
register values as read and the missed reads, then the raw-bytes lines and the
settings.

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
