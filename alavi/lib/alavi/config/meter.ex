defmodule Alavi.Config.Meter do
  @moduledoc """
  One meter on an endpoint's chain. Every round its identity is read, then every
  register of its profile.

  `serial` is the serial expected at this address, or nil when it is not known.
  Readings always carry the serial the meter reports; a different one is logged.
  """

  alias Alavi.Config.Fields
  alias Alavi.Profile

  @enforce_keys [:unit_id, :serial, :profile, :interval_ms]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          unit_id: 1..247,
          serial: String.t() | nil,
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
         {:ok, profile} <- profile(entry, profiles),
         {:ok, serial} <- serial(entry, profile),
         {:ok, interval} <- interval(entry, endpoint_interval) do
      {:ok,
       %__MODULE__{unit_id: unit_id, serial: serial, profile: profile, interval_ms: interval}}
    end
  end

  def parse(_entry, _interval, _profiles), do: {:error, "meter entry is not an object"}

  defp profile(entry, profiles) do
    with {:ok, name} <- Fields.string(entry, "profile"),
         {:ok, profile} <- loaded(profiles, name),
         do: identified(profile)
  end

  defp loaded(profiles, name) do
    case Map.fetch(profiles, name) do
      {:ok, profile} -> {:ok, profile}
      :error -> {:error, "profile #{inspect(name)} is not among the loaded profiles"}
    end
  end

  # Readings carry the serial and product code read, so a profile must say where they are.
  defp identified(%Profile{identity: %{serial: %{}, product_code: %{}}} = profile),
    do: {:ok, profile}

  defp identified(%Profile{name: name}),
    do:
      {:error,
       "profile #{name} has no identity.serial or identity.product_code check, " <>
         "and readings must carry both as read"}

  defp serial(entry, _profile) when not is_map_key(entry, "serial"), do: {:ok, nil}

  defp serial(entry, %Profile{name: name, identity: %{serial: %{count: count}}}) do
    with {:ok, serial} <- Fields.string(entry, "serial"),
         :ok <- readable(serial),
         :ok <- fits(serial, count * 2, name),
         do: {:ok, serial}
  end

  # A serial read is printable ASCII, trimmed: anything else could never match one.
  defp readable(serial) do
    if serial =~ ~r/\A[\x21-\x7E]([\x20-\x7E]*[\x21-\x7E])?\z/,
      do: :ok,
      else:
        {:error, "serial #{inspect(serial)} is not printable ASCII without surrounding spaces"}
  end

  defp fits(serial, chars, _name) when byte_size(serial) <= chars, do: :ok

  defp fits(serial, chars, name),
    do:
      {:error,
       "serial #{inspect(serial)} is longer than the #{chars} characters " <>
         "profile #{name}'s serial registers hold"}

  defp interval(entry, _endpoint_interval) when is_map_key(entry, "interval_ms"),
    do: Fields.integer(entry, "interval_ms", 1..@max_ms)

  defp interval(_entry, endpoint_interval), do: {:ok, endpoint_interval}
end
