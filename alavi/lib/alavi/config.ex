defmodule Alavi.Config do
  @moduledoc """
  The collector's polling config: which endpoints and meters to read, and how.
  `load/2` reads a local file; `parse/2` takes a decoded document.

  ## Document, schema version 1

      {
        "schema_version": 1,
        "endpoints": [
          {
            "host": "10.0.0.21", "port": 502, "framing": "tcp", "max_timeouts": 3,
            "polled_by_other_system": false,
            "timeout_ms": 1000, "retries": 2, "busy_backoff_ms": 500,
            "reconnect_backoff_ms": {"min": 1000, "max": 60000},
            "interval_ms": 900000,
            "meters": [
              {"unit_id": 1, "serial": "SIM-0001", "profile": "elite_440"},
              {"unit_id": 3, "profile": "elite_500", "interval_ms": 60000}
            ]
          }
        ]
      }

  Field meanings are in `Alavi.Config.Endpoint` and `Alavi.Config.Meter`.
  """

  alias Alavi.Config.{Endpoint, Fields}
  alias Alavi.Profile

  @enforce_keys [:endpoints]
  defstruct @enforce_keys

  @type t :: %__MODULE__{endpoints: [Endpoint.t(), ...]}

  # contract: test/alavi/config_test.exs "load/2"
  @spec load(Path.t(), %{String.t() => Profile.t()}) :: {:ok, t()} | {:error, String.t()}
  def load(path, profiles) do
    with {:ok, text} <- read(path),
         {:ok, json} <- decode(path, text) do
      case parse(json, profiles) do
        {:ok, config} -> {:ok, config}
        {:error, reason} -> {:error, "#{path}: #{reason}"}
      end
    end
  end

  # contract: test/alavi/config_test.exs "parse/2"
  @spec parse(term(), %{String.t() => Profile.t()}) :: {:ok, t()} | {:error, String.t()}
  def parse(%{"schema_version" => 1} = json, profiles) do
    with :ok <- Fields.only(json, ["schema_version", "endpoints"]),
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

  defp read(path) do
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
