defmodule Alavi.Profile do
  @moduledoc """
  A meter model's register map, as data in `contract/profiles/*.json`, shared
  with the simulator and the server.
  """

  alias Alavi.Profile.{Firmware, Identity, Register}

  @enforce_keys [:name, :models, :sources, :identity, :firmware, :registers]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          name: String.t(),
          models: [String.t()],
          sources: [Register.source()],
          identity: Identity.t(),
          firmware: Firmware.t() | nil,
          registers: [Register.t()]
        }

  @spec load(Path.t()) :: {:ok, t()} | {:error, String.t()}
  def load(path) do
    with {:ok, text} <- read(path),
         {:ok, json} <- decode(path, text) do
      case parse(json) do
        {:ok, profile} -> {:ok, profile}
        {:error, reason} -> {:error, "#{path}: #{reason}"}
      end
    end
  end

  # Lists the directory rather than globbing it: `Path.wildcard` reads `\` as an
  # escape, so a Windows path written with backslashes would match nothing.
  @spec load_dir(Path.t()) :: {:ok, %{String.t() => t()}} | {:error, String.t()}
  def load_dir(dir) do
    with {:ok, names} <- list(dir) do
      names
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.sort()
      |> Enum.map(&Path.join(dir, &1))
      |> load_all()
    end
  end

  defp list(dir) do
    case File.ls(dir) do
      {:ok, names} -> {:ok, names}
      {:error, reason} -> {:error, "#{dir}: #{:file.format_error(reason)}"}
    end
  end

  defp load_all(paths) do
    Enum.reduce_while(paths, {:ok, %{}}, fn path, {:ok, acc} ->
      case load(path) do
        {:ok, %{name: name}} when is_map_key(acc, name) ->
          {:halt, {:error, "#{path}: profile #{name} is defined in another file too"}}

        {:ok, profile} ->
          {:cont, {:ok, Map.put(acc, profile.name, profile)}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  # contract: test/alavi/profile_test.exs "parse/1"
  @spec parse(term()) :: {:ok, t()} | {:error, String.t()}
  def parse(
        %{
          "schema_version" => 1,
          "profile" => name,
          "models" => [_ | _] = models,
          "sources" => [_ | _] = source_entries,
          "identity" => identity_json,
          "registers" => [_ | _] = entries
        } = json
      )
      when is_binary(name) do
    with {:ok, sources} <- parse_sources(source_entries),
         {:ok, identity} <- Identity.parse(identity_json),
         {:ok, firmware} <- parse_firmware(json),
         {:ok, registers} <- parse_registers(entries),
         :ok <- unique_keys(registers),
         :ok <- known_sources(sources, identity, firmware, registers) do
      {:ok,
       %__MODULE__{
         name: name,
         models: models,
         sources: sources,
         identity: identity,
         firmware: firmware,
         registers: registers
       }}
    end
  end

  def parse(%{"schema_version" => version}) when version != 1,
    do: {:error, "unsupported profile schema_version #{inspect(version)}"}

  def parse(_json),
    do:
      {:error,
       "expected schema_version, profile, models, a non-empty sources list, identity, optionally firmware, and a non-empty registers list"}

  @spec register(t(), String.t()) :: {:ok, Register.t()} | {:error, :unknown_register}
  def register(%__MODULE__{registers: registers}, key) do
    case Enum.find(registers, &(&1.key == key)) do
      nil -> {:error, :unknown_register}
      register -> {:ok, register}
    end
  end

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

  defp parse_sources(entries) do
    case Enum.find(entries, &match?({:error, _}, Register.parse_source(&1))) do
      nil -> unique_sources(entries)
      bad -> {:error, "sources: " <> elem(Register.parse_source(bad), 1)}
    end
  end

  defp unique_sources(ids) do
    if length(Enum.uniq(ids)) == length(ids),
      do: {:ok, ids},
      else: {:error, "sources lists an ID more than once"}
  end

  defp known_sources(sources, identity, firmware, registers) do
    used =
      Identity.sources(identity) ++
        firmware_sources(firmware) ++ for(%{source: id} <- registers, id != nil, do: id)

    case Enum.reject(used, &(&1 in sources)) do
      [] -> :ok
      [id | _] -> {:error, "source #{inspect(id)} is not in sources"}
    end
  end

  defp parse_firmware(%{"firmware" => json}), do: Firmware.parse(json)
  defp parse_firmware(_json), do: {:ok, nil}

  defp firmware_sources(nil), do: []
  defp firmware_sources(firmware), do: Firmware.sources(firmware)

  defp parse_registers(entries) do
    entries
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, acc} ->
      case Register.parse(entry) do
        {:ok, register} -> {:cont, {:ok, [register | acc]}}
        {:error, reason} -> {:halt, {:error, "registers[#{index}]: #{reason}"}}
      end
    end)
    |> then(fn
      {:ok, registers} -> {:ok, Enum.reverse(registers)}
      error -> error
    end)
  end

  defp unique_keys(registers) do
    case registers |> Enum.frequencies_by(& &1.key) |> Enum.find(fn {_, n} -> n > 1 end) do
      nil -> :ok
      {key, _} -> {:error, "register key #{key} appears more than once"}
    end
  end
end
