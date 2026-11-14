defmodule Alavi.Intake.Resolve do
  @moduledoc """
  Which endpoint and unit each requested serial is at, among the meters this
  collector polls. The meter at a unit is taken to be the one whose serial
  was last read there; at a unit none has been read at since start, the one
  the polling config expects. So a serial configured at a unit that has
  since read another resolves nowhere. Pure.
  """

  alias Alavi.Config.Endpoint

  @type endpoint :: {String.t(), :inet.port_number()}
  @typedoc "The serial last read at each unit, per endpoint (`Alavi.Pollers.serials/1`)."
  @type observed :: %{endpoint() => %{(1..247) => String.t()}}
  @type unresolved :: {String.t(), :not_polled | :ambiguous}

  # contract: test/alavi/intake_test.exs "Resolve.plan/3"
  @doc """
  The units to read per endpoint, each endpoint's in the order asked, and
  the serials that resolve to no unit, or to more than one.
  """
  @spec plan([Endpoint.t()], observed(), [String.t()]) ::
          {[{endpoint(), [1..247, ...]}], [unresolved()]}
  def plan(endpoints, observed, serials) do
    index = endpoints |> holders(observed) |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    {found, unresolved} =
      Enum.reduce(serials, {[], []}, fn serial, {found, unresolved} ->
        case Map.get(index, serial, []) do
          [at] -> {[at | found], unresolved}
          [] -> {found, [{serial, :not_polled} | unresolved]}
          [_, _ | _] -> {found, [{serial, :ambiguous} | unresolved]}
        end
      end)

    {by_endpoint(Enum.reverse(found)), Enum.reverse(unresolved)}
  end

  defp holders(endpoints, observed) do
    for %Endpoint{polled_by_other_system: false} = e <- endpoints,
        read = Map.get(observed, {e.host, e.port}, %{}),
        meter <- e.meters,
        serial = Map.get(read, meter.unit_id, meter.serial),
        serial != nil,
        do: {serial, {{e.host, e.port}, meter.unit_id}}
  end

  defp by_endpoint(found) do
    found
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.sort_by(fn {endpoint, _units} ->
      Enum.find_index(found, &(elem(&1, 0) == endpoint))
    end)
  end
end
