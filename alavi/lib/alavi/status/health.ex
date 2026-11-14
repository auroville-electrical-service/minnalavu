defmodule Alavi.Status.Health do
  @moduledoc """
  What is wrong, judged from an `Alavi.Status.Snapshot`'s endpoints by their
  last round only: what the status page summarises. Pure; it changes nothing.

  An endpoint is `:waiting` before its first round, `:down` when every unit
  missed in its last round, `:degraded` when some unit did not read fully or a
  meter's serial read is not the one expected, and `:ok` otherwise. A meter is
  `:waiting` until a round has an outcome for it, then that outcome.
  """

  alias Alavi.Status.Snapshot

  @type endpoint_state :: :ok | :degraded | :down | :waiting
  @type meter_state :: :ok | :partial | :missed | :waiting

  @typedoc "How many endpoints and meters are in each state, and meters whose serial is not the one expected."
  @type counts :: %{
          endpoints: %{endpoint_state() => non_neg_integer()},
          meters: %{meter_state() => non_neg_integer()},
          mismatched: non_neg_integer()
        }

  @endpoint_states [:ok, :degraded, :down, :waiting]
  @meter_states [:ok, :partial, :missed, :waiting]

  # contract: test/alavi/status/page_test.exs "render/2"
  @spec endpoint(Snapshot.endpoint()) :: endpoint_state()
  def endpoint(%{rounds: []}), do: :waiting

  def endpoint(%{rounds: [last | _]} = e) do
    cond do
      Enum.all?(last.units, &(&1.outcome == "missed")) -> :down
      Enum.any?(last.units, &(&1.outcome != "ok")) -> :degraded
      Enum.any?(e.meters, &mismatched?/1) -> :degraded
      true -> :ok
    end
  end

  # contract: test/alavi/status/page_test.exs "render/2"
  @doc "The meter's outcome in its endpoint's last round."
  @spec meter(Snapshot.endpoint(), Snapshot.meter()) :: meter_state()
  def meter(%{rounds: []}, _meter), do: :waiting

  def meter(%{rounds: [last | _]}, %{unit_id: unit}) do
    case Enum.find(last.units, &(&1.unit_id == unit)) do
      nil -> :waiting
      %{outcome: outcome} -> state(outcome)
    end
  end

  # contract: test/alavi/status/page_test.exs "render/2"
  @doc "A serial was read, one was configured, and they differ."
  @spec mismatched?(Snapshot.meter()) :: boolean()
  def mismatched?(%{serial_expected: nil}), do: false
  def mismatched?(%{serial: nil}), do: false
  def mismatched?(%{serial_expected: expected, serial: read}), do: expected != read

  # contract: test/alavi/status/page_test.exs "render/2"
  @spec counts(Snapshot.t()) :: counts()
  def counts(%Snapshot{endpoints: endpoints}) do
    meters = for e <- endpoints, m <- e.meters, do: {e, m}

    %{
      endpoints: tally(endpoints, @endpoint_states, &endpoint/1),
      meters: tally(meters, @meter_states, fn {e, m} -> meter(e, m) end),
      mismatched: Enum.count(meters, fn {_e, m} -> mismatched?(m) end)
    }
  end

  defp tally(items, states, state_of) do
    zero = Map.new(states, &{&1, 0})
    Enum.reduce(items, zero, fn item, acc -> Map.update!(acc, state_of.(item), &(&1 + 1)) end)
  end

  defp state("ok"), do: :ok
  defp state("partial"), do: :partial
  defp state("missed"), do: :missed
end
