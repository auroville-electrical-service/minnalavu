defmodule Alavi.Config.Meter do
  @moduledoc """
  One meter on an endpoint's chain. Every register of its profile is read each
  round.
  """

  alias Alavi.Config.Fields
  alias Alavi.Profile

  @enforce_keys [:unit_id, :serial, :profile, :interval_ms]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          unit_id: 1..247,
          serial: String.t(),
          profile: Profile.t(),
          interval_ms: pos_integer()
        }

  @max_ms 86_400_000

  # contract: test/alavi/config_test.exs "parse/2"
  @doc false
  @spec parse(term(), pos_integer(), %{String.t() => Profile.t()}) ::
          {:ok, t()} | {:error, String.t()}
  def parse(entry, endpoint_interval, profiles) when is_map(entry) do
    with :ok <- Fields.only(entry, ["unit_id", "serial", "profile", "interval_ms"]),
         {:ok, unit_id} <- Fields.integer(entry, "unit_id", 1..247),
         {:ok, serial} <- Fields.string(entry, "serial"),
         {:ok, profile} <- profile(entry, profiles),
         {:ok, interval} <- interval(entry, endpoint_interval) do
      {:ok,
       %__MODULE__{unit_id: unit_id, serial: serial, profile: profile, interval_ms: interval}}
    end
  end

  def parse(_entry, _interval, _profiles), do: {:error, "meter entry is not an object"}

  defp profile(entry, profiles) do
    with {:ok, name} <- Fields.string(entry, "profile") do
      case Map.fetch(profiles, name) do
        {:ok, profile} -> {:ok, profile}
        :error -> {:error, "profile #{inspect(name)} is not among the loaded profiles"}
      end
    end
  end

  defp interval(entry, _endpoint_interval) when is_map_key(entry, "interval_ms"),
    do: Fields.integer(entry, "interval_ms", 1..@max_ms)

  defp interval(_entry, endpoint_interval), do: {:ok, endpoint_interval}
end
