defmodule Alavi.LatencyDayFixture do
  @moduledoc "Latency days, one with answers and one of timeouts only, for the tests that carry them."

  alias Alavi.LatencyDay
  alias Alavi.Poller.Latency

  @endpoint %{host: "10.0.0.21", port: 502}

  @doc "Answers at 3, 38, 40, 41 and 75000 ms, and 44 ms on a retry; one timeout; two late data replies and a late 0B."
  @spec answered() :: LatencyDay.t()
  def answered do
    [3, 38, 40, 41, 75_000]
    |> Enum.reduce(Latency.new(), &Latency.record(&2, ~D[2026-11-14], 1, &1, :ok))
    |> Latency.record(~D[2026-11-14], 2, 44, :ok)
    |> Latency.record(~D[2026-11-14], 1, 3_000, :timeout)
    |> Latency.late(~D[2026-11-14], :data)
    |> Latency.late(~D[2026-11-14], :data)
    |> Latency.late(~D[2026-11-14], {:exception, 11})
    |> day(1)
  end

  @spec timeouts_only() :: LatencyDay.t()
  def timeouts_only do
    Latency.new() |> Latency.record(~D[2026-11-14], 1, 3_000, :timeout) |> day(3)
  end

  defp day(latency, unit) do
    counts = Latency.counts(latency, ~D[2026-11-14])
    LatencyDay.new(@endpoint, unit, ~U[2026-11-13 18:30:00.250000Z], ~D[2026-11-14], counts)
  end
end
