defmodule Alavi.StatusFixture do
  @moduledoc """
  Generated snapshots of a large collector, through `Alavi.Status.Snapshot`'s
  public functions: endpoints at 10.0.x.y:502, five meters each by default
  (alternately elite_440 and elite_500), every meter read with firmware names,
  and the snapshot's round history full.
  """

  import Alavi.PollerCase, only: [config!: 1, endpoint: 4, meter: 3]

  alias Alavi.{FirmwareRead, MissedRead, Reading}
  alias Alavi.Status.Snapshot

  @now ~U[2026-11-14 10:00:00Z]
  @rounds 10

  @typedoc """
  `down`: endpoint indexes (1-based) whose every read times out;
  `missing`: `{endpoint index, unit_id}` meters that do not answer.
  """
  @type option :: {:down, [pos_integer()]} | {:missing, [{pos_integer(), 1..247}]}

  @spec snapshot(pos_integer(), pos_integer(), [option()]) :: Snapshot.t()
  def snapshot(meters, per_endpoint \\ 5, opts \\ []) do
    down = Keyword.get(opts, :down, [])
    missing = Keyword.get(opts, :missing, [])
    config = config(meters, per_endpoint)
    settings = [{"status.port", 8502}, {"server.url", "https://central.example/"}]
    initial = Snapshot.new(config, settings, "0.1.0", @now)

    config.endpoints
    |> Enum.with_index(1)
    |> Enum.reduce(initial, fn {e, n}, snapshot ->
      fail = fn unit -> n in down or {n, unit} in missing end
      feed(snapshot, e, fail)
    end)
    |> Snapshot.uplink({:stored, "batch-1"}, 60_000, @now)
    |> Snapshot.backlog(backlog(), @now)
  end

  @doc "The endpoint as the snapshot names it."
  @spec host(pos_integer()) :: String.t()
  def host(n), do: "10.0.#{div(n, 250)}.#{rem(n, 250) + 1}"

  defp config(meters, per_endpoint) do
    meters
    |> then(&Enum.chunk_every(1..&1, per_endpoint))
    |> Enum.with_index(1)
    |> Enum.map(fn {ids, n} ->
      units = Enum.map(ids, &unit(&1, per_endpoint))
      endpoint(502, "tcp", units, %{"host" => host(n)})
    end)
    |> config!()
  end

  defp unit(id, per_endpoint),
    do: meter(rem(id - 1, per_endpoint) + 1, profile(id), %{"serial" => "SIM-#{id}"})

  defp profile(id) when rem(id, 2) == 0, do: "elite_500"
  defp profile(_id), do: "elite_440"

  defp feed(snapshot, e, fail) do
    at = fn round -> DateTime.add(@now, (round - @rounds) * 60, :second) end

    snapshot =
      Enum.reduce(1..@rounds, snapshot, fn round, s ->
        Snapshot.round(s, Enum.flat_map(e.meters, &events(e, &1, at.(round), fail)))
      end)

    e.meters
    |> Enum.reject(&fail.(&1.unit_id))
    |> Enum.reduce(snapshot, &Snapshot.firmware(&2, firmware(e, &1)))
  end

  defp events(e, m, at, fail) do
    Enum.map(m.profile.registers, fn r ->
      if fail.(m.unit_id), do: missed(e, m, r, at), else: reading(e, m, r, at)
    end)
  end

  defp reading(e, m, r, at) do
    %Reading{
      endpoint: %{host: e.host, port: e.port},
      unit_id: m.unit_id,
      meter_serial: m.serial,
      product_code: "ELITE440-445",
      profile: m.profile.name,
      register_key: r.key,
      timestamp: at,
      raw_words: [0, 1],
      value: Decimal.new("123456.789"),
      unit: r.unit
    }
  end

  defp missed(e, m, r, at) do
    %MissedRead{
      endpoint: %{host: e.host, port: e.port},
      unit_id: m.unit_id,
      meter_serial: nil,
      profile: m.profile.name,
      register_key: r.key,
      timestamp: at,
      reason: :timeout,
      attempts: 3,
      raw_words: nil
    }
  end

  defp firmware(e, m) do
    %FirmwareRead{
      endpoint: %{host: e.host, port: e.port},
      unit_id: m.unit_id,
      meter_serial: m.serial,
      product_code: "ELITE440-445",
      timestamp: @now,
      software: "SIM-SW",
      firmware_1: "SIM-F1",
      firmware_2: "SIM-F2",
      modbus_version: "0100"
    }
  end

  defp backlog do
    %{
      events: 1_000,
      bytes: 50_000,
      batches: 3,
      oldest: @now,
      max_bytes: 1_000_000_000,
      refused: 0,
      discarded_files: 0,
      quarantined: 0
    }
  end
end
