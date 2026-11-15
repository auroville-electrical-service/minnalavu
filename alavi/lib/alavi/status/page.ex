defmodule Alavi.Status.Page do
  @moduledoc """
  The status pages, from an `Alavi.Status.Snapshot`, with no script and no
  form. The summary (`render/2`) stays small whatever the number of meters: the
  collector, clock, uplink and buffer, endpoints and meters counted by state
  (`Alavi.Status.Health`), in full only what is not OK in its last round, and
  a link to each endpoint's own page (`endpoint/3`), which holds its rounds,
  failures and meters with their register values. Every value from the
  snapshot is escaped: serials, product codes and raw-bytes lines come from
  devices. Measurement only: values as read, never a difference between two.
  """

  alias Alavi.Status.{Health, Snapshot}

  @style """
  body{font:14px/1.4 system-ui,sans-serif;margin:16px;color:#111;background:#fff}
  h1{font-size:20px}h2{font-size:17px;margin-top:28px;border-bottom:1px solid #999}
  h3{font-size:15px;margin-top:20px}
  table{border-collapse:collapse;margin:4px 0 8px}
  th,td{border:1px solid #ccc;padding:2px 6px;text-align:left;vertical-align:top}
  th{background:#eee}
  code,.mono{font-family:monospace;word-break:break-all}
  .bad{background:#fdd;color:#900;font-weight:bold}.warn{background:#ffe8b0}
  .ok{color:#060}.note{color:#555}.eps a{margin-right:10px;white-space:nowrap}
  """

  @states [
    ok: "OK",
    degraded: "some units not OK",
    down: "down",
    waiting: "no round yet",
    faulted: "faulted: selector restore owed"
  ]
  @latency_heads ["Unit", "Since", "Answered", "On a retry", "Timed out"] ++
                   ["p50 ms", "p90 ms", "p99 ms", "Max ms"]
  @meter_states [ok: "OK", partial: "partial", missed: "missed", waiting: "not read yet"]

  # contract: test/alavi/status/page_test.exs "render/2"
  @doc "The summary page, refreshing itself every `refresh_s` seconds."
  @spec render(Snapshot.t(), pos_integer()) :: String.t()
  def render(%Snapshot{} = s, refresh_s) do
    numbered = Enum.with_index(s.endpoints, 1)

    page("alavi status", refresh_s, [
      "<h1>alavi collector status</h1>",
      ~s|<p class="note">Refreshes every #{refresh_s} s. This page only shows; it changes |,
      ~s|nothing. Times are UTC. The same data: <a href="/status.json">status.json</a>.</p>|,
      summary(s),
      counts(Health.counts(s)),
      not_ok(numbered),
      links(numbered),
      raw_lines(s.raw_lines),
      settings(s.settings)
    ])
  end

  # contract: test/alavi/status/page_test.exs "endpoint/3"
  @doc "The page of the `n`th endpoint in the polling config, from 1; `:error` if there is none."
  @spec endpoint(Snapshot.t(), pos_integer(), pos_integer()) :: {:ok, String.t()} | :error
  def endpoint(%Snapshot{endpoints: endpoints}, n, refresh_s) do
    case Enum.at(endpoints, n - 1) do
      nil ->
        :error

      e ->
        {:ok, page("alavi status: #{e.host}:#{e.port}", refresh_s, endpoint_body(e, refresh_s))}
    end
  end

  defp page(title, refresh_s, body) do
    IO.iodata_to_binary([
      ~s|<!doctype html><html lang="en"><head><meta charset="utf-8">|,
      ~s|<meta http-equiv="refresh" content="#{refresh_s}">|,
      ~s|<meta name="viewport" content="width=device-width, initial-scale=1">|,
      "<title>",
      text(title),
      "</title><style>",
      @style,
      "</style></head><body>",
      body,
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
      "<h3>Clock check</h3>",
      clock_check(s.clock_check),
      "<h3>Uplink</h3>",
      uplink(s.uplink),
      "<h3>Buffer</h3>",
      buffer(s.buffer)
    ]
  end

  defp clock_source("unsynced"), do: bad("unsynced")
  defp clock_source(source), do: text(source)

  defp clock_check(nil), do: ~s|<p class="note">No check yet, or none configured.</p>|

  defp clock_check(c) do
    pairs([
      {"Last check", [text(c.at), " (", text(c.trigger), ")"]},
      {"Server", [text(c.server), address(c.address)]},
      {"Outcome", check_outcome(c.outcome)},
      {"Stratum", or_none(c.stratum)},
      {"Offset (server minus collector, ms; display only)", or_none(c.offset_ms)}
    ])
  end

  defp address(nil), do: []
  defp address(ip), do: [" at ", text(ip)]

  defp check_outcome("answered"), do: ok("answered")
  defp check_outcome(outcome), do: bad(outcome)

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
    rows =
      backlog |> Enum.sort() |> Enum.map(fn {key, value} -> {text(key), count(key, value)} end)

    pairs([{"As of", text(at)} | rows])
  end

  # Batches the buffer refused, discarded or quarantined are each a fault to look into.
  defp count(key, n) when key in ["refused", "discarded_files", "quarantined"] and n > 0,
    do: bad(n)

  defp count(_key, value), do: or_none(value)

  defp counts(c) do
    [
      "<h2>Endpoints and meters</h2>",
      "<p>By their last round.</p>",
      tally("Endpoints", c.endpoints, @states),
      tally("Meters", c.meters, @meter_states),
      pairs([{"Meters whose serial read is not the one expected", missed(c.mismatched)}])
    ]
  end

  defp tally(what, counts, states) do
    total = counts |> Map.values() |> Enum.sum()
    cells = Enum.map(states, fn {state, _} -> tally_cell(state, counts[state]) end)
    ["<h3>", what, "</h3>", table(["Total" | Keyword.values(states)], [[text(total) | cells]])]
  end

  defp tally_cell(state, n) when state in [:ok, :waiting] or n == 0, do: text(n)
  defp tally_cell(_state, n), do: bad(n)

  # One row per endpoint, the units grouped by what went wrong: the table stays
  # short when many meters fail together.
  defp not_ok(numbered) do
    rows =
      numbered
      |> Enum.map(fn {e, n} -> {e, n, Health.endpoint(e)} end)
      |> Enum.filter(fn {_e, _n, state} -> state in [:faulted, :down, :degraded] end)
      |> Enum.map(fn {e, n, state} ->
        [endpoint_link(e, n), text(label(state)), last_round(e.rounds), wrong(state, e)]
      end)

    [
      "<h2>Not OK</h2>",
      case rows do
        [] -> none("Every endpoint polled so far read every meter in its last round.")
        rows -> table(["Endpoint", "State", "Last round", "Not OK in it"], rows)
      end
    ]
  end

  defp last_round([]), do: none_text("none yet")
  defp last_round([last | _]), do: text(last.at)

  defp wrong(:faulted, %{selectors: s} = e) do
    restore = ["selector restore owed, ", text(s.attempts), " attempts: ", text(s.detail)]
    if e.rounds == [], do: restore, else: [restore, "; ", wrong(:degraded, e)]
  end

  defp wrong(_state, e) do
    groups =
      hd(e.rounds).units
      |> Enum.reject(&(&1.outcome == "ok"))
      |> Enum.group_by(&{&1.outcome, &1.reason}, & &1.unit_id)
      |> Enum.sort()
      |> Enum.map(fn {{outcome, reason}, units} ->
        [text(outcome), " (", text(reason), "): ", ids(units)]
      end)

    mismatches = e.meters |> Enum.filter(&Health.mismatched?/1) |> Enum.map(&mismatch/1)
    Enum.intersperse(groups ++ mismatches, "; ")
  end

  defp ids([unit]), do: ["unit ", text(unit)]
  defp ids(units), do: ["units ", Enum.map_join(units, ", ", &text/1)]

  defp mismatch(m) do
    ["unit ", text(m.unit_id), " serial ", text(m.serial)] ++
      [~s| <span class="bad">MISMATCH</span> (expected |, text(m.serial_expected), ")"]
  end

  defp links(numbered) do
    links =
      for {e, n} <- numbered,
          Health.endpoint(e) in [:ok, :waiting],
          do: [endpoint_link(e, n), " "]

    [
      "<h2>Endpoints OK or not polled yet</h2>",
      ~s|<p class="note">Each endpoint's rounds, failures and meters with their register |,
      "values are on its own page, linked here and under Not OK.</p>",
      case links do
        [] -> none("None.")
        links -> [~s|<p class="eps">|, links, "</p>"]
      end
    ]
  end

  defp endpoint_link(e, n),
    do: [~s|<a href="/endpoint/#{n}">|, text(e.host), ":", text(e.port), "</a>"]

  defp label(state), do: Keyword.fetch!(@states, state)

  defp endpoint_body(e, refresh_s) do
    state = Health.endpoint(e)

    [
      "<h1>alavi endpoint ",
      text(e.host),
      ":",
      text(e.port),
      "</h1>",
      ~s|<p class="note">Refreshes every #{refresh_s} s. This page only shows; it changes |,
      ~s|nothing. Times are UTC. <a href="/">Back to the summary</a>.</p>|,
      pairs([
        {"State in its last round",
         if(state in [:ok, :waiting], do: text(label(state)), else: bad(label(state)))},
        {"Selectors", selectors(e.selectors)},
        {"Framing", text(e.framing)},
        {"Polled by another system", text(e.polled_by_other_system)}
      ]),
      "<h2>Last rounds</h2>",
      rounds(e.rounds),
      "<h2>Recent failures</h2>",
      failures(e.failures),
      "<h2>Request latency</h2>",
      latency(e.meters),
      "<h2>Meters</h2>",
      Enum.map(e.meters, &meter(e, &1))
    ]
  end

  defp selectors(nil), do: none_text("never written")
  defp selectors(%{state: "restored"} = s), do: [ok("restored"), " at ", text(s.at)]

  defp selectors(%{state: "owed"} = s) do
    [bad("restore owed"), " at ", text(s.at), ", after ", text(s.attempts), " attempts: "] ++
      [or_none(s.detail), "; polls go on, no copy starts"]
  end

  defp selectors(%{state: "refused"} = s),
    do: [warn("session refused"), " at ", text(s.at), ", nothing written: ", or_none(s.detail)]

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

  defp latency(meters) do
    rows = for %{latency: l} = m <- meters, l != nil, do: latency_row(m.unit_id, l)

    [
      ~s|<p class="note">Each request's round trip since the collector started, from the |,
      "UTC day shown, a week at most. A percentile is at most the figure shown; a ",
      "timeout is counted, never a sample.</p>",
      case rows do
        [] -> none("No request yet.")
        rows -> table(@latency_heads, rows)
      end
    ]
  end

  defp latency_row(unit, l) do
    [text(unit), text(l.since), text(l.answered), text(l.retries), timeouts(l.timeouts)] ++
      Enum.map([l.p50, l.p90, l.p99, l.max], &or_none/1)
  end

  defp timeouts(0), do: text(0)
  defp timeouts(n), do: warn(n)

  defp meter(e, m) do
    state = Health.meter(e, m)

    [
      "<h3>Unit ",
      text(m.unit_id),
      ": ",
      text(m.profile),
      "</h3>",
      pairs([
        {"Last round", meter_state(state)},
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

  defp meter_state(state) when state in [:ok, :waiting],
    do: text(Keyword.fetch!(@meter_states, state))

  defp meter_state(state), do: bad(Keyword.fetch!(@meter_states, state))

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
  defp warn(value), do: [~s|<span class="warn">|, text(value), "</span>"]
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
