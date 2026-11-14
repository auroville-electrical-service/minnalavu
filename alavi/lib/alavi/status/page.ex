defmodule Alavi.Status.Page do
  @moduledoc """
  The status page: an `Alavi.Status.Snapshot` as one HTML document, with no
  script, no form and no link but the one to `status.json`. Every value from
  the snapshot is escaped: serials, product codes and raw-bytes lines come from
  devices. Measurement only: values as read, never a difference between two.
  """

  alias Alavi.Status.Snapshot

  @style """
  body{font:14px/1.4 system-ui,sans-serif;margin:16px;color:#111;background:#fff}
  h1{font-size:20px}h2{font-size:17px;margin-top:28px;border-bottom:1px solid #999}
  h3{font-size:15px;margin-top:20px}h4{font-size:14px;margin:14px 0 4px}
  table{border-collapse:collapse;margin:4px 0 8px}
  th,td{border:1px solid #ccc;padding:2px 6px;text-align:left;vertical-align:top}
  th{background:#eee}
  code,.mono{font-family:monospace;word-break:break-all}
  .bad{background:#fdd;color:#900;font-weight:bold}.warn{background:#ffe8b0}
  .ok{color:#060}.note{color:#555}
  """

  # contract: test/alavi/status/web_test.exs "GET /"
  @doc "The page, refreshing itself every `refresh_s` seconds."
  @spec render(Snapshot.t(), pos_integer()) :: String.t()
  def render(%Snapshot{} = s, refresh_s) do
    IO.iodata_to_binary([
      ~s|<!doctype html><html lang="en"><head><meta charset="utf-8">|,
      ~s|<meta http-equiv="refresh" content="#{refresh_s}">|,
      ~s|<meta name="viewport" content="width=device-width, initial-scale=1">|,
      "<title>alavi status</title><style>",
      @style,
      "</style></head><body><h1>alavi collector status</h1>",
      ~s|<p class="note">Refreshes every #{refresh_s} s. This page only shows; it changes |,
      ~s|nothing. Times are UTC. The same data: <a href="/status.json">status.json</a>.</p>|,
      summary(s),
      "<h2>Endpoints</h2>",
      Enum.map(s.endpoints, &endpoint/1),
      raw_lines(s.raw_lines),
      settings(s.settings),
      "</body></html>"
    ])
  end

  defp summary(s) do
    [
      "<h2>Summary</h2>",
      pairs([
        {"Version", text(s.version)},
        {"Started at", text(s.started_at)},
        {"Clock source", clock_source(s.clock.source)},
        {"Clock last synced", or_none(s.clock.last_sync_at, "never")}
      ]),
      "<h3>Uplink</h3>",
      uplink(s.uplink),
      "<h3>Buffer</h3>",
      buffer(s.buffer)
    ]
  end

  defp clock_source("unsynced"), do: bad("unsynced")
  defp clock_source(source), do: text(source)

  defp uplink(nil), do: ~s|<p class="note">No attempt yet.</p>|

  defp uplink(u) do
    pairs([
      {"Last attempt", text(u.last_attempt_at)},
      {"Result", uplink_result(u.result)},
      {"Batch", or_none(u.batch_id)},
      {"Detail", or_none(u.detail)},
      {"Next attempt", text(u.next_attempt_at)}
    ])
  end

  defp uplink_result(result) when result in ["stored", "empty"], do: ok(result)
  defp uplink_result(result), do: bad(result)

  defp buffer(nil), do: ~s|<p class="note">Not asked yet.</p>|

  defp buffer(%{as_of: at, backlog: nil}),
    do: [~s|<p class="bad">The buffer did not answer at |, text(at), ".</p>"]

  defp buffer(%{as_of: at, backlog: backlog}) do
    rows = backlog |> Enum.sort() |> Enum.map(fn {key, value} -> {text(key), or_none(value)} end)
    pairs([{"As of", text(at)} | rows])
  end

  defp endpoint(e) do
    [
      "<h3>",
      text(e.host),
      ":",
      text(e.port),
      "</h3>",
      pairs([
        {"Framing", text(e.framing)},
        {"Polled by another system", text(e.polled_by_other_system)}
      ]),
      "<h4>Last rounds</h4>",
      rounds(e.rounds),
      "<h4>Recent failures</h4>",
      failures(e.failures),
      Enum.map(e.meters, &meter/1)
    ]
  end

  defp rounds([]), do: none("No round yet.")

  defp rounds(rounds),
    do:
      table(
        ["At", "Per unit"],
        Enum.map(rounds, fn r -> [text(r.at), Enum.map(r.units, &unit/1)] end)
      )

  defp unit(%{outcome: "ok"} = u),
    do: [~s|<span class="ok">unit |, text(u.unit_id), " ok</span> "]

  defp unit(u) do
    [
      ~s|<span class="bad">unit |,
      text(u.unit_id),
      " ",
      text(u.outcome),
      " (",
      text(u.reason),
      ")</span> "
    ]
  end

  defp failures([]), do: none("None.")

  defp failures(failures) do
    table(
      ["At", "Unit", "Serial", "Register", "Reason", "Exception code", "Detail", "Attempts"],
      Enum.map(failures, fn f ->
        [text(f.at), text(f.unit_id), or_none(f.meter_serial), text(f.register_key)] ++
          [bad(f.reason), or_none(f.exception_code), or_none(f.detail), text(f.attempts)]
      end)
    )
  end

  defp meter(m) do
    [
      "<h4>Unit ",
      text(m.unit_id),
      ": ",
      text(m.profile),
      "</h4>",
      pairs([
        {"Last read", or_none(m.last_read_at, "never")},
        {"Serial expected", or_none(m.serial_expected, "not configured")},
        {"Serial read", serial(m.serial_expected, m.serial)},
        {"Product code read", or_none(m.product_code, "not read yet")},
        {"Firmware read", firmware(m.firmware)},
        {"Missed reads since start", missed(m.missed_reads)}
      ]),
      registers(m.registers)
    ]
  end

  defp serial(_expected, nil), do: none_text("not read yet")
  defp serial(expected, expected), do: ok(expected)
  defp serial(nil, read), do: text(read)
  defp serial(_expected, read), do: [bad(read), ~s| <span class="bad">MISMATCH</span>|]

  defp firmware(nil), do: none_text("not read yet")

  defp firmware(f) do
    names = [f.software, f.firmware_1, f.firmware_2, f.modbus_version]
    [Enum.map_intersperse(names, " / ", &or_none(&1, "not given")), " at ", text(f.read_at)]
  end

  defp missed(0), do: text(0)
  defp missed(n), do: bad(n)

  defp registers(registers) do
    table(
      ["Register", "Value", "Unit", "Read at", "Source"],
      Enum.map(registers, fn r ->
        [text(r.key), [~s|<span class="mono">|, or_none(r.value, "not read yet"), "</span>"]] ++
          [text(r.unit), or_none(r.read_at), source(r)]
      end)
    )
  end

  defp source(%{placeholder: true} = r),
    do: [or_none(r.source), ~s| <span class="warn">placeholder</span>|]

  defp source(r), do: or_none(r.source)

  defp raw_lines(lines) do
    [
      "<h2>Raw bytes of unexpected replies</h2>",
      case lines do
        [] -> none("None since start.")
        lines -> table(["At", "Line"], Enum.map(lines, &[text(&1.at), code(&1.line)]))
      end
    ]
  end

  defp settings(settings) do
    [
      "<h2>Settings</h2>",
      ~s|<p class="note">As read at start. The token is never shown.</p>|,
      table(["Setting", "Value"], Enum.map(settings, &[code(&1.key), code(&1.value)]))
    ]
  end

  defp pairs(rows) do
    [
      "<table>",
      Enum.map(rows, fn {k, v} -> ["<tr><th>", k, "</th><td>", v, "</td></tr>"] end),
      "</table>"
    ]
  end

  defp table(heads, rows) do
    [
      "<table><tr>",
      Enum.map(heads, &["<th>", &1, "</th>"]),
      "</tr>",
      Enum.map(rows, fn row -> ["<tr>", Enum.map(row, &["<td>", &1, "</td>"]), "</tr>"] end),
      "</table>"
    ]
  end

  defp ok(value), do: [~s|<span class="ok">|, text(value), "</span>"]
  defp bad(value), do: [~s|<span class="bad">|, text(value), "</span>"]
  defp code(value), do: ["<code>", text(value), "</code>"]
  defp none(message), do: [~s|<p class="note">|, message, "</p>"]
  defp none_text(message), do: [~s|<span class="note">|, message, "</span>"]

  defp or_none(value, absent \\ "none")
  defp or_none(nil, absent), do: none_text(absent)
  defp or_none(value, _absent), do: text(value)

  defp text(value), do: value |> to_string() |> escape()

  defp escape(string) do
    for <<char <- string>>, into: "" do
      case char do
        ?& -> "&amp;"
        ?< -> "&lt;"
        ?> -> "&gt;"
        ?" -> "&quot;"
        ?' -> "&#39;"
        other -> <<other>>
      end
    end
  end
end
