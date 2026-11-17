defmodule Alavi.Status.Snapshot do
  @rounds 10
  @failures 20
  @raw_lines 50

  @moduledoc """
  What the collector is doing, as pure data: what the status page renders and
  `status.json` holds. Every leaf is JSON-ready (strings, integers, booleans,
  nil; times as ISO 8601 UTC, but for a meter's next due time, ISO 8601 in
  the collector's local time with its offset; register values as decimal strings), so nothing
  in it refers to what the poller or the buffer hold.

  History is bounded: per endpoint the last #{@rounds} rounds and
  #{@failures} failures, and the last #{@raw_lines} raw-bytes lines, newest
  first. It is lost on restart; the
  log and the buffer are the durable record. Measurement only: register values
  as read, never a difference between two of them.
  """

  alias Alavi.{Buffer, Clock, ClockCheck, Config, FirmwareRead, MissedRead, Reading, Wire}
  alias Alavi.Config.{Endpoint, Meter}
  alias Alavi.Poller.Latency
  alias Alavi.Profile.Register

  @enforce_keys [
    :version,
    :started_at,
    :settings,
    :clock,
    :clock_check,
    :buffer,
    :uplink,
    :config,
    :endpoints,
    :raw_lines
  ]
  defstruct @enforce_keys

  @type time :: String.t()

  @type register :: %{
          key: String.t(),
          unit: String.t(),
          source: String.t() | nil,
          placeholder: boolean(),
          value: String.t() | nil,
          read_at: time() | nil
        }

  @typedoc "A meter's names as last read; a name is nil where the meter did not give it."
  @type firmware :: %{
          read_at: time(),
          software: String.t() | nil,
          firmware_1: String.t() | nil,
          firmware_2: String.t() | nil,
          modbus_version: String.t() | nil
        }

  @typedoc """
  Request latency over the poller's last days, from `since`, a UTC date (see
  `Alavi.Poller.Latency`): answers, those on a retry, timeouts, and
  percentiles and the maximum in ms, nil while nothing answered.
  """
  @type latency :: %{
          since: String.t(),
          answered: non_neg_integer(),
          retries: non_neg_integer(),
          timeouts: non_neg_integer(),
          p50: non_neg_integer() | nil,
          p90: non_neg_integer() | nil,
          p99: non_neg_integer() | nil,
          max: non_neg_integer() | nil
        }

  @typedoc """
  When a meter is next due, in the collector's local time with its offset
  (`2026-11-17T06:00:00+05:30`), a time past while it is due, and whether
  on a retry after a round that got no answer from it.
  """
  @type schedule :: %{next_due_at: String.t(), retrying: boolean()}

  @typedoc """
  `serial_expected` is the polling config's; `serial` and `product_code` are
  as last read with a reading. `missed_reads` counts since the collector
  started. `next_due_at` and `retrying` are `schedule()`'s, nil and false
  until its poller reports.
  """
  @type meter :: %{
          unit_id: 1..247,
          profile: String.t(),
          serial_expected: String.t() | nil,
          last_read_at: time() | nil,
          serial: String.t() | nil,
          product_code: String.t() | nil,
          registers: [register()],
          missed_reads: non_neg_integer(),
          firmware: firmware() | nil,
          latency: latency() | nil,
          next_due_at: String.t() | nil,
          retrying: boolean()
        }

  @typedoc "`reason` and its `exception_code` and `detail` are as on the wire (batch.v1)."
  @type failure :: %{
          at: time(),
          unit_id: 1..247,
          meter_serial: String.t() | nil,
          register_key: String.t(),
          reason: String.t(),
          exception_code: integer() | nil,
          detail: String.t() | nil,
          attempts: non_neg_integer()
        }

  @typedoc "`ok`: every register read; `partial`: some; `missed`: none, for `reason`."
  @type outcome :: %{unit_id: 1..247, outcome: String.t(), reason: String.t() | nil}

  @type round :: %{at: time(), units: [outcome()]}

  @typedoc """
  An endpoint's selectors, nil until a restore or session reports: `owed`, a
  restore not yet done (the endpoint is faulted), with `attempts` made;
  `restored`; `refused`, a session not opened, nothing written. `detail`
  says why.
  """
  @type selectors :: %{
          state: String.t(),
          detail: String.t() | nil,
          at: time(),
          attempts: non_neg_integer()
        }

  @type selectors_event ::
          {:owed, String.t(), non_neg_integer()} | :restored | {:refused, String.t()}

  @typedoc """
  An endpoint's copies of its meters' stored entries: `enabled` and the
  collector's `window` (local time, HH:MM) as configured, and `state`: `off`;
  `waiting` for the window; `scanning` a store's stamps (`entry` the slot
  count reached, `of` the entries held) or `copying` it (`entry` done `of`
  due), on `unit_id`; then how the night's copy ended: `done` for tonight,
  `window_closed` or `retiring` before it was done, `faulted` with a restore
  owed. `not_finite` counts the quantities and intervals not sent for a NaN
  under a supported mask bit, since start; `last_error` is the last meter's
  copy that failed.
  """
  @type copy :: %{
          enabled: boolean(),
          window: %{start: String.t(), end: String.t()},
          state: String.t(),
          at: time() | nil,
          unit_id: 1..247 | nil,
          store: String.t() | nil,
          entry: non_neg_integer() | nil,
          of: non_neg_integer() | nil,
          not_finite: non_neg_integer(),
          last_error: %{at: time(), unit_id: 1..247, detail: String.t()} | nil
        }

  @type copy_event ::
          {:at, 1..247, :history | :snapshot | :load_survey, :scanning | :copying,
           non_neg_integer(), non_neg_integer()}
          | {:not_finite, pos_integer()}
          | {:error, 1..247, String.t()}
          | {:finished, :done | :window | :retiring | :fault}

  @type endpoint :: %{
          host: String.t(),
          port: :inet.port_number(),
          framing: String.t(),
          polled_by_other_system: boolean(),
          rounds: [round()],
          failures: [failure()],
          meters: [meter()],
          selectors: selectors() | nil,
          copy: copy()
        }

  @typedoc "`result`: `stored`, `quarantined`, `not_sent` (retried later) or `empty`."
  @type uplink :: %{
          last_attempt_at: time(),
          result: String.t(),
          batch_id: String.t() | nil,
          detail: String.t() | nil,
          next_attempt_at: time()
        }

  @typedoc """
  The last query of the last clock check, as on the wire, with the offset it
  implies (`Alavi.ClockCheck.offset_ms/1`: the server's clock minus the
  collector's), for display and never sent. `address` and `stratum` are nil
  where no server's reply named them, `offset_ms` unless it answered.
  """
  @type clock_check :: %{
          at: time(),
          trigger: String.t(),
          server: String.t(),
          outcome: String.t(),
          address: String.t() | nil,
          stratum: 1..15 | nil,
          offset_ms: integer() | nil
        }

  @typedoc "As on the wire's `backlog`, with when it was asked; `nil` if the buffer did not answer."
  @type buffer :: %{as_of: time(), backlog: %{String.t() => term()} | nil}

  @typedoc "As a batch's backlog reports it (`Alavi.Wire.config/1`)."
  @type config :: %{String.t() => String.t() | nil}

  @typedoc "What the uplink did with one attempt."
  @type uplink_result ::
          {:stored, String.t()}
          | {:quarantined, String.t(), String.t()}
          | {:not_sent, String.t(), String.t()}
          | :empty

  @type t :: %__MODULE__{
          version: String.t(),
          started_at: time(),
          settings: [%{key: String.t(), value: String.t() | integer()}],
          clock: %{source: String.t(), last_sync_at: time() | nil},
          clock_check: clock_check() | nil,
          buffer: buffer() | nil,
          uplink: uplink() | nil,
          config: config() | nil,
          endpoints: [endpoint()],
          raw_lines: [%{at: time(), line: String.t()}]
        }

  # contract: test/alavi/status_test.exs "Snapshot.new/4"
  @doc "`settings` are `Alavi.Settings.shown/1`'s: never the token."
  @spec new(Config.t(), [{String.t(), String.t() | integer()}], String.t(), DateTime.t()) :: t()
  def new(%Config{endpoints: endpoints, copy_window: window}, settings, version, now) do
    %__MODULE__{
      version: version,
      started_at: iso(now),
      settings: Enum.map(settings, fn {key, value} -> %{key: key, value: value} end),
      clock: clock_view(Clock.unsynced()),
      clock_check: nil,
      buffer: nil,
      uplink: nil,
      config: nil,
      endpoints: Enum.map(endpoints, &endpoint(&1, window)),
      raw_lines: []
    }
  end

  # contract: test/alavi/status_test.exs "Snapshot.round/2"
  @doc "One poller round's events, all from one endpoint; an endpoint not in the config is ignored."
  @spec round(t(), [Reading.t() | MissedRead.t(), ...]) :: t()
  def round(%__MODULE__{} = snapshot, [_ | _] = events),
    do: on_endpoint(snapshot, events, &round_of/2)

  # contract: test/alavi/status_test.exs "Snapshot.on_demand/2"
  @doc """
  A read on demand's events, all from one endpoint: its meters' values and
  failures, as a round's, but no round, which stays a whole chain's.
  """
  @spec on_demand(t(), [Reading.t() | MissedRead.t(), ...]) :: t()
  def on_demand(%__MODULE__{} = snapshot, [_ | _] = events),
    do: on_endpoint(snapshot, events, &read_of/2)

  defp on_endpoint(snapshot, [%{endpoint: %{host: host, port: port}} | _] = events, update) do
    endpoints =
      Enum.map(snapshot.endpoints, fn
        %{host: ^host, port: ^port} = endpoint -> update.(endpoint, events)
        endpoint -> endpoint
      end)

    %{snapshot | endpoints: endpoints}
  end

  # contract: test/alavi/status_test.exs "Snapshot.firmware/2"
  @doc "An endpoint or unit not in the config is ignored."
  @spec firmware(t(), FirmwareRead.t()) :: t()
  def firmware(%__MODULE__{} = snapshot, %FirmwareRead{} = f) do
    view = %{
      read_at: iso(f.timestamp),
      software: f.software,
      firmware_1: f.firmware_1,
      firmware_2: f.firmware_2,
      modbus_version: f.modbus_version
    }

    on_meters(snapshot, f.endpoint, &firmware_of(&1, f.unit_id, view))
  end

  # contract: test/alavi/status_test.exs "Snapshot.latency/3"
  @doc "An endpoint's latency per meter, by unit ID; an endpoint or unit not in the config is ignored."
  @spec latency(
          t(),
          %{host: String.t(), port: :inet.port_number()},
          %{(1..247) => Latency.summary() | nil}
        ) :: t()
  def latency(%__MODULE__{} = snapshot, endpoint, by_unit),
    do: on_meters(snapshot, endpoint, &latency_of(&1, by_unit))

  defp on_meters(snapshot, %{host: host, port: port}, update) do
    endpoints =
      Enum.map(snapshot.endpoints, fn
        %{host: ^host, port: ^port} = endpoint ->
          %{endpoint | meters: Enum.map(endpoint.meters, update)}

        endpoint ->
          endpoint
      end)

    %{snapshot | endpoints: endpoints}
  end

  # contract: test/alavi/status_test.exs "Snapshot.schedule/3"
  @doc "When an endpoint's meters, by unit ID, are next due; an endpoint or unit not in the config is ignored."
  @spec schedule(
          t(),
          %{host: String.t(), port: :inet.port_number()},
          %{(1..247) => schedule()}
        ) :: t()
  def schedule(%__MODULE__{} = snapshot, endpoint, by_unit),
    do: on_meters(snapshot, endpoint, &Map.merge(&1, Map.get(by_unit, &1.unit_id, %{})))

  # contract: test/alavi/status_test.exs "Snapshot.selectors/4"
  @doc "An endpoint not in the config is ignored."
  @spec selectors(
          t(),
          %{host: String.t(), port: :inet.port_number()},
          selectors_event(),
          DateTime.t()
        ) :: t()
  def selectors(%__MODULE__{} = snapshot, %{host: host, port: port}, event, now) do
    {state, detail, attempts} = selectors_view(event)
    view = %{state: state, detail: detail, at: iso(now), attempts: attempts}

    endpoints =
      Enum.map(snapshot.endpoints, fn
        %{host: ^host, port: ^port} = endpoint -> %{endpoint | selectors: view}
        endpoint -> endpoint
      end)

    %{snapshot | endpoints: endpoints}
  end

  # contract: test/alavi/status_test.exs "Snapshot.copy/4"
  @doc "An endpoint not in the config is ignored."
  @spec copy(t(), %{host: String.t(), port: :inet.port_number()}, copy_event(), DateTime.t()) ::
          t()
  def copy(%__MODULE__{} = snapshot, %{host: host, port: port}, event, now) do
    endpoints =
      Enum.map(snapshot.endpoints, fn
        %{host: ^host, port: ^port} = endpoint ->
          %{endpoint | copy: copied(endpoint.copy, event, iso(now))}

        endpoint ->
          endpoint
      end)

    %{snapshot | endpoints: endpoints}
  end

  defp copied(copy, {:at, unit, store, phase, n, m}, at),
    do: %{
      copy
      | state: Atom.to_string(phase),
        at: at,
        unit_id: unit,
        store: Atom.to_string(store),
        entry: n,
        of: m
    }

  defp copied(copy, {:not_finite, n}, _at), do: %{copy | not_finite: copy.not_finite + n}

  defp copied(copy, {:error, unit, detail}, at),
    do: %{copy | last_error: %{at: at, unit_id: unit, detail: detail}}

  defp copied(copy, {:finished, outcome}, at),
    do: %{copy | state: finished(outcome), at: at, unit_id: nil, store: nil, entry: nil, of: nil}

  defp finished(:done), do: "done"
  defp finished(:window), do: "window_closed"
  defp finished(:retiring), do: "retiring"
  defp finished(:fault), do: "faulted"

  defp selectors_view({:owed, detail, attempts}), do: {"owed", detail, attempts}
  defp selectors_view(:restored), do: {"restored", nil, 0}
  defp selectors_view({:refused, detail}), do: {"refused", detail, 0}

  # contract: test/alavi/status_test.exs "Snapshot.raw_lines/3"
  @spec raw_lines(t(), [String.t()], DateTime.t()) :: t()
  def raw_lines(%__MODULE__{} = snapshot, lines, now) do
    added = lines |> Enum.reverse() |> Enum.map(&%{at: iso(now), line: &1})
    %{snapshot | raw_lines: Enum.take(added ++ snapshot.raw_lines, @raw_lines)}
  end

  # contract: test/alavi/status_test.exs "Snapshot.uplink/4"
  @doc "`next_ms`: how long until the uplink's next attempt."
  @spec uplink(t(), uplink_result(), non_neg_integer(), DateTime.t()) :: t()
  def uplink(%__MODULE__{} = snapshot, result, next_ms, now) do
    {name, batch, detail} = result(result)

    uplink = %{
      last_attempt_at: iso(now),
      result: name,
      batch_id: batch,
      detail: detail,
      next_attempt_at: now |> DateTime.add(next_ms, :millisecond) |> iso()
    }

    %{snapshot | uplink: uplink}
  end

  # contract: test/alavi/status_test.exs "Snapshot.config/2"
  @spec config(t(), Alavi.ConfigKeeper.report()) :: t()
  def config(%__MODULE__{} = snapshot, report), do: %{snapshot | config: Wire.config(report)}

  # contract: test/alavi/status_test.exs "Snapshot.polling/2"
  @doc """
  The endpoints of a new polling config: one at the host and port of an
  endpoint shown keeps its rounds, failures and selectors, and each of its
  meters at the same unit, with the same profile, expected serial and
  registers, keeps what was read; the rest start afresh, and an endpoint the
  config no longer has goes.
  """
  @spec polling(t(), Config.t()) :: t()
  def polling(%__MODULE__{} = snapshot, %Config{endpoints: endpoints, copy_window: window}) do
    shown = Map.new(snapshot.endpoints, &{{&1.host, &1.port}, &1})
    %{snapshot | endpoints: Enum.map(endpoints, &carried(endpoint(&1, window), shown))}
  end

  defp carried(fresh, shown) do
    case Map.fetch(shown, {fresh.host, fresh.port}) do
      {:ok, old} ->
        meters = Map.new(old.meters, &{&1.unit_id, &1})

        %{
          fresh
          | rounds: old.rounds,
            failures: old.failures,
            selectors: old.selectors,
            copy: carried_copy(fresh.copy, old.copy),
            meters: Enum.map(fresh.meters, &carried_meter(&1, meters[&1.unit_id]))
        }

      :error ->
        fresh
    end
  end

  # A copy switched or windowed differently starts afresh, as its poller does.
  defp carried_copy(%{enabled: e, window: w} = _fresh, %{enabled: e, window: w} = old), do: old
  defp carried_copy(fresh, _old), do: fresh

  defp carried_meter(fresh, nil), do: fresh

  defp carried_meter(fresh, old),
    do: if(configured(old) == configured(fresh), do: old, else: fresh)

  defp configured(meter),
    do: {
      Map.take(meter, [:unit_id, :profile, :serial_expected]),
      Enum.map(meter.registers, &Map.drop(&1, [:value, :read_at]))
    }

  # contract: test/alavi/status_test.exs "Snapshot.clock/2"
  @spec clock(t(), Clock.status()) :: t()
  def clock(%__MODULE__{} = snapshot, status), do: %{snapshot | clock: clock_view(status)}

  # contract: test/alavi/status_test.exs "Snapshot.clock_check/2"
  @spec clock_check(t(), ClockCheck.t()) :: t()
  def clock_check(%__MODULE__{} = snapshot, %ClockCheck{} = check) do
    wire = ClockCheck.to_wire(check)

    view = %{
      at: wire["t1"],
      trigger: wire["trigger"],
      server: wire["server"],
      outcome: wire["outcome"],
      address: wire["address"],
      stratum: wire["stratum"],
      offset_ms: ClockCheck.offset_ms(check)
    }

    %{snapshot | clock_check: view}
  end

  # contract: test/alavi/status_test.exs "Snapshot.backlog/3"
  @spec backlog(t(), Buffer.backlog() | :unavailable, DateTime.t()) :: t()
  def backlog(%__MODULE__{} = snapshot, :unavailable, now),
    do: %{snapshot | buffer: %{as_of: iso(now), backlog: nil}}

  def backlog(%__MODULE__{} = snapshot, backlog, now),
    do: %{snapshot | buffer: %{as_of: iso(now), backlog: Wire.backlog(backlog)}}

  # contract: test/alavi/status_test.exs "Snapshot.to_json/1"
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = snapshot),
    do: snapshot |> Map.from_struct() |> Map.put(:format, "alavi-status.v1") |> JSON.encode!()

  defp endpoint(%Endpoint{} = e, window) do
    %{
      host: e.host,
      port: e.port,
      framing: Atom.to_string(e.framing),
      polled_by_other_system: e.polled_by_other_system,
      rounds: [],
      failures: [],
      meters: Enum.map(e.meters, &meter/1),
      selectors: nil,
      copy: %{
        enabled: e.copy,
        window: %{start: hhmm(window.start), end: hhmm(window.end)},
        state: if(e.copy, do: "waiting", else: "off"),
        at: nil,
        unit_id: nil,
        store: nil,
        entry: nil,
        of: nil,
        not_finite: 0,
        last_error: nil
      }
    }
  end

  defp hhmm(time), do: time |> Time.to_string() |> binary_part(0, 5)

  defp meter(%Meter{} = m) do
    %{
      unit_id: m.unit_id,
      profile: m.profile.name,
      serial_expected: m.serial,
      last_read_at: nil,
      serial: nil,
      product_code: nil,
      registers: Enum.map(m.profile.registers, &register/1),
      missed_reads: 0,
      firmware: nil,
      latency: nil,
      next_due_at: nil,
      retrying: false
    }
  end

  defp register(%Register{} = r),
    do: %{
      key: r.key,
      unit: r.unit,
      source: r.source,
      placeholder: r.placeholder,
      value: nil,
      read_at: nil
    }

  defp round_of(endpoint, events) do
    outcomes =
      events
      |> Enum.group_by(& &1.unit_id)
      |> Enum.sort()
      |> Enum.map(fn {unit, evs} -> outcome(unit, evs) end)

    round = %{at: events |> List.last() |> Map.fetch!(:timestamp) |> iso(), units: outcomes}
    %{read_of(endpoint, events) | rounds: Enum.take([round | endpoint.rounds], @rounds)}
  end

  defp read_of(endpoint, events) do
    by_unit = Enum.group_by(events, & &1.unit_id)
    missed = events |> Enum.filter(&match?(%MissedRead{}, &1)) |> Enum.reverse()

    %{
      endpoint
      | failures: Enum.take(Enum.map(missed, &failure/1) ++ endpoint.failures, @failures),
        meters: Enum.map(endpoint.meters, &meter_of(&1, Map.get(by_unit, &1.unit_id)))
    }
  end

  defp outcome(unit, events) do
    case Enum.split_with(events, &match?(%Reading{}, &1)) do
      {_read, []} -> %{unit_id: unit, outcome: "ok", reason: nil}
      {[], [first | _]} -> %{unit_id: unit, outcome: "missed", reason: reason(first)}
      {_read, [first | _]} -> %{unit_id: unit, outcome: "partial", reason: reason(first)}
    end
  end

  defp failure(%MissedRead{} = m) do
    wire = MissedRead.to_wire(m)

    %{
      at: wire["timestamp"],
      unit_id: m.unit_id,
      meter_serial: m.meter_serial,
      register_key: m.register_key,
      reason: wire["reason"],
      exception_code: wire["exception_code"],
      detail: wire["detail"],
      attempts: m.attempts
    }
  end

  defp firmware_of(%{unit_id: unit} = meter, unit, view), do: %{meter | firmware: view}
  defp firmware_of(meter, _unit, _view), do: meter

  defp latency_of(%{unit_id: unit} = meter, by_unit) do
    case Map.fetch(by_unit, unit) do
      {:ok, nil} -> meter
      {:ok, summary} -> %{meter | latency: %{summary | since: Date.to_iso8601(summary.since)}}
      :error -> meter
    end
  end

  defp meter_of(meter, nil), do: meter
  defp meter_of(meter, events), do: Enum.reduce(events, meter, &event/2)

  defp event(%Reading{} = r, meter) do
    at = iso(r.timestamp)
    value = Decimal.to_string(r.value, :normal)

    registers =
      Enum.map(meter.registers, fn
        %{key: key} = reg when key == r.register_key -> %{reg | value: value, read_at: at}
        reg -> reg
      end)

    %{
      meter
      | last_read_at: at,
        serial: r.meter_serial,
        product_code: r.product_code,
        registers: registers
    }
  end

  defp event(%MissedRead{}, meter), do: %{meter | missed_reads: meter.missed_reads + 1}

  defp reason(%MissedRead{} = m), do: MissedRead.to_wire(m)["reason"]

  defp result({:stored, batch}), do: {"stored", batch, nil}
  defp result({:quarantined, batch, why}), do: {"quarantined", batch, why}
  defp result({:not_sent, batch, why}), do: {"not_sent", batch, why}
  defp result(:empty), do: {"empty", nil, nil}

  defp clock_view(%{source: source, last_sync_at: at}),
    do: %{source: Atom.to_string(source), last_sync_at: at && iso(at)}

  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
end
