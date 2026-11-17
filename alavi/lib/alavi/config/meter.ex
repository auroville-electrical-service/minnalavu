defmodule Alavi.Config.Meter do
  @moduledoc """
  One meter on an endpoint's chain. Every round its identity is read, then every
  register of its profile.

  `serial` is the serial expected at this address, or nil when it is not known.
  Readings always carry the serial the meter reports; a different one is logged.
  `interval_ms` and `retry_ms` are the meter's own, or else its endpoint's.
  """

  alias Alavi.Config.{Fields, Schema}
  alias Alavi.Profile

  @enforce_keys [:unit_id, :serial, :profile, :interval_ms, :retry_ms]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          unit_id: 1..247,
          serial: String.t() | nil,
          profile: Profile.t(),
          interval_ms: pos_integer(),
          retry_ms: pos_integer()
        }

  @path ["endpoints", "meters"]
  @printable "printable ASCII without surrounding spaces"
  @fields Schema.fields(@path)
  @unit_id Schema.range(@path ++ ["unit_id"])
  @serial Schema.pattern(@path ++ ["serial"])
  @profile Schema.pattern(@path ++ ["profile"])
  @interval Schema.range(@path ++ ["interval_ms"])
  @retry Schema.range(@path ++ ["retry_ms"])

  # contract: test/alavi/config_test.exs "parse/2"
  @doc false
  @spec parse(
          term(),
          %{interval_ms: pos_integer(), retry_ms: pos_integer()},
          %{String.t() => Profile.t()}
        ) :: {:ok, t()} | {:error, String.t()}
  def parse(entry, %{} = endpoint, profiles) when is_map(entry) do
    with :ok <- Fields.only(entry, @fields),
         {:ok, unit_id} <- Fields.integer(entry, "unit_id", @unit_id),
         {:ok, profile} <- profile(entry, profiles),
         {:ok, serial} <- serial(entry, profile),
         {:ok, interval} <-
           own(entry, "interval_ms", endpoint.interval_ms, &Fields.interval/3, @interval),
         {:ok, retry} <- own(entry, "retry_ms", endpoint.retry_ms, &Fields.integer/3, @retry) do
      {:ok,
       %__MODULE__{
         unit_id: unit_id,
         serial: serial,
         profile: profile,
         interval_ms: interval,
         retry_ms: retry
       }}
    end
  end

  def parse(_entry, _endpoint, _profiles), do: {:error, "meter entry is not an object"}

  defp profile(entry, profiles) do
    with {:ok, name} <- Fields.matching(entry, "profile", @profile, "a profile name"),
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
    with {:ok, serial} <- Fields.matching(entry, "serial", @serial, @printable),
         :ok <- fits(serial, count * 2, name),
         do: {:ok, serial}
  end

  defp fits(serial, chars, _name) when byte_size(serial) <= chars, do: :ok

  defp fits(serial, chars, name),
    do:
      {:error,
       "serial #{inspect(serial)} is longer than the #{chars} characters " <>
         "profile #{name}'s serial registers hold"}

  defp own(entry, field, _endpoint, parse, range) when is_map_key(entry, field),
    do: parse.(entry, field, range)

  defp own(_entry, _field, endpoint, _parse, _range), do: {:ok, endpoint}
end
