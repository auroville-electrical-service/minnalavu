defmodule Alavi.Config do
  @moduledoc """
  The collector's polling config: which endpoints and meters to read, and how.
  `read/1` decodes a local file; `parse/2` parses a decoded document, from
  the file or as the server served it (`Alavi.ConfigKeeper`).

  The document is schema version 1 of `contract/config/config.v1.schema.json`,
  which gives each field's meaning; its fields and limits are read from there
  when alavi compiles. `contract/fixtures/config.v1.basic.json` is an example.
  """

  alias Alavi.Config.{Endpoint, Fields, Schema}
  alias Alavi.Profile

  @fields Schema.fields([])

  @enforce_keys [:endpoints]
  defstruct @enforce_keys

  @type t :: %__MODULE__{endpoints: [Endpoint.t(), ...]}

  # contract: test/alavi/config_test.exs "read/1"
  @doc "The document in a local file, decoded but not parsed."
  @spec read(Path.t()) :: {:ok, term()} | {:error, String.t()}
  def read(path) do
    with {:ok, text} <- read_file(path), do: decode(path, text)
  end

  # contract: test/alavi/config_test.exs "parse/2"
  @spec parse(term(), %{String.t() => Profile.t()}) :: {:ok, t()} | {:error, String.t()}
  def parse(%{"schema_version" => 1} = json, profiles) do
    with :ok <- Fields.only(json, @fields),
         {:ok, endpoints} <- Fields.each(json, "endpoints", &Endpoint.parse(&1, profiles)),
         :ok <- Fields.unique(endpoints, &{&1.host, &1.port}, "endpoint"),
         :ok <- Fields.unique(expected_serials(endpoints), & &1, "serial") do
      {:ok, %__MODULE__{endpoints: endpoints}}
    end
  end

  def parse(%{"schema_version" => version}, _profiles),
    do: {:error, "unsupported config schema_version #{inspect(version)}"}

  def parse(_json, _profiles),
    do: {:error, "expected an object with schema_version and endpoints"}

  defp expected_serials(endpoints),
    do: for(%{meters: meters} <- endpoints, %{serial: s} <- meters, s != nil, do: s)

  defp read_file(path) do
    case File.read(path) do
      {:ok, text} -> {:ok, text}
      {:error, reason} -> {:error, "#{path}: #{:file.format_error(reason)}"}
    end
  end

  defp decode(path, text) do
    case JSON.decode(text) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, "#{path}: invalid JSON (#{inspect(reason)})"}
    end
  end
end
