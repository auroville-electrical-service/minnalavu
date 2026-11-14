defmodule Alavi.Status.Snapshot do
  @rounds 10
  @failures 20
  @raw_lines 50

  @moduledoc """
  What the collector is doing, as pure data: what the status page renders and
  `status.json` holds. Every leaf is JSON-ready (strings, integers, booleans,
  nil; times as ISO 8601 UTC, register values as decimal strings), so nothing
  in it refers to what the poller or the buffer hold.

  History is bounded: per endpoint the last #{@rounds} rounds and
  #{@failures} failures, and the last #{@raw_lines} raw-bytes lines, newest
  first. It is lost on restart; the
  log and the buffer are the durable record. Measurement only: register values
  as read, never a difference between two of them.
  """

  alias Alavi.{Buffer, Clock, Config, MissedRead, Reading, Wire}
  alias Alavi.Config.{Endpoint, Meter}
  alias Alavi.Profile.Register

  @enforce_keys [
    :version,
    :started_at,
    :settings,
    :clock,
    :buffer,
    :uplink,
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

  @typedoc """
  `serial_expected` is the polling config's; `serial` and `product_code` are
  as last read with a reading. `missed_reads` counts since the collector started.
  """
  @type meter :: %{
          unit_id: 1..247,
          profile: String.t(),
          serial_expected: String.t() | nil,
          last_read_at: time() | nil,
          serial: String.t() | nil,
          product_code: String.t() | nil,
          registers: [register()],
          missed_reads: non_neg_integer()
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

  @type endpoint :: %{
          host: String.t(),
          port: :inet.port_number(),
          framing: String.t(),
          polled_by_other_system: boolean(),
          rounds: [round()],
          failures: [failure()],
          meters: [meter()]
        }

  @typedoc "`result`: `stored`, `quarantined`, `not_sent` (retried later) or `empty`."
  @type uplink :: %{
          last_attempt_at: time(),
          result: String.t(),
          batch_id: String.t() | nil,
          detail: String.t() | nil,
          next_attempt_at: time()
        }

  @typedoc "As on the wire's `backlog`, with when it was asked; `nil` if the buffer did not answer."
  @type buffer :: %{as_of: time(), backlog: %{String.t() => term()} | nil}

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
          buffer: buffer() | nil,
          uplink: uplink() | nil,
          endpoints: [endpoint()],
          raw_lines: [%{at: time(), line: String.t()}]
        }

  # contract: test/alavi/status_test.exs "Snapshot.new/4"
  @doc "`settings` are `Alavi.Settings.shown/1`'s: never the token."
  @spec new(Config.t(), [{String.t(), String.t() | integer()}], String.t(), DateTime.t()) :: t()
  def new(%Config{endpoints: endpoints}, settings, version, now) do
    %__MODULE__{
      version: version,
      started_at: iso(now),
      settings: Enum.map(settings, fn {key, value} -> %{key: key, value: value} end),
      clock: clock_view(Clock.unsynced()),
      buffer: nil,
      uplink: nil,
      endpoints: Enum.map(endpoints, &endpoint/1),
      raw_lines: []
    }
  end

  # contract: test/alavi/status_test.exs "Snapshot.round/2"
  @doc "One poller round's events, all from one endpoint; an endpoint not in the config is ignored."
  @spec round(t(), [Reading.t() | MissedRead.t(), ...]) :: t()
  def round(%__MODULE__{} = snapshot, [%{endpoint: %{host: host, port: port}} | _] = events) do
    endpoints =
      Enum.map(snapshot.endpoints, fn
        %{host: ^host, port: ^port} = endpoint -> round_of(endpoint, events)
        endpoint -> endpoint
      end)

    %{snapshot | endpoints: endpoints}
  end

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

  # contract: test/alavi/status_test.exs "Snapshot.clock/2"
  @spec clock(t(), Clock.status()) :: t()
  def clock(%__MODULE__{} = snapshot, status), do: %{snapshot | clock: clock_view(status)}

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

  defp endpoint(%Endpoint{} = e) do
    %{
      host: e.host,
      port: e.port,
      framing: Atom.to_string(e.framing),
      polled_by_other_system: e.polled_by_other_system,
      rounds: [],
      failures: [],
      meters: Enum.map(e.meters, &meter/1)
    }
  end

  defp meter(%Meter{} = m) do
    %{
      unit_id: m.unit_id,
      profile: m.profile.name,
      serial_expected: m.serial,
      last_read_at: nil,
      serial: nil,
      product_code: nil,
      registers: Enum.map(m.profile.registers, &register/1),
      missed_reads: 0
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
    by_unit = Enum.group_by(events, & &1.unit_id)
    outcomes = by_unit |> Enum.sort() |> Enum.map(fn {unit, evs} -> outcome(unit, evs) end)
    round = %{at: events |> List.last() |> Map.fetch!(:timestamp) |> iso(), units: outcomes}
    missed = events |> Enum.filter(&match?(%MissedRead{}, &1)) |> Enum.reverse()

    %{
      endpoint
      | rounds: Enum.take([round | endpoint.rounds], @rounds),
        failures: Enum.take(Enum.map(missed, &failure/1) ++ endpoint.failures, @failures),
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
