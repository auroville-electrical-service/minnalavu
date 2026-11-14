defmodule Alavi.Selectors.Record do
  @moduledoc """
  The selector values one endpoint's sessions keep on disk, as pure data and
  their JSON:

  - an owed restore (`t`): the meter a session is on, and each selector it
    may write with the value it held before the session's first write and the
    bound that value was checked against (`Alavi.Modbus.Selector.request/4`);
  - what was left (`left`): the value each selector was last restored to and
    read back, by unit, model and name, which the next session must find.

  Each format is versioned. A file that does not parse whole, or names
  another endpoint, is refused, never read in part.
  """

  alias Alavi.Modbus.Selector

  @enforce_keys [:endpoint, :unit_id, :model, :selectors]
  defstruct @enforce_keys

  @type endpoint :: %{host: String.t(), port: :inet.port_number()}
  @type selector :: %{name: Selector.name(), value: 0..0xFFFF, bound: integer()}
  @type t :: %__MODULE__{
          endpoint: endpoint(),
          unit_id: 1..247,
          model: Selector.model(),
          selectors: [selector(), ...]
        }
  @type left :: %{{1..247, Selector.model(), Selector.name()} => 0..0xFFFF}

  @owed "alavi-selector-restore.v1"
  @left "alavi-selectors-left.v1"

  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{} = record) do
    JSON.encode!(%{
      "format" => @owed,
      "endpoint" => endpoint_json(record.endpoint),
      "unit_id" => record.unit_id,
      "model" => record.model,
      "selectors" =>
        Enum.map(record.selectors, fn s ->
          %{"name" => Atom.to_string(s.name), "value" => s.value, "bound" => s.bound}
        end)
    })
  end

  # contract: test/alavi/selectors/record_test.exs "parse/2"
  @spec parse(binary(), endpoint()) :: {:ok, t()} | {:error, String.t()}
  def parse(text, endpoint) do
    with {:ok, json} <- decode(text),
         :ok <- header(json, @owed, endpoint, ~w(unit_id model)),
         {:ok, unit} <- unit(json["unit_id"]),
         {:ok, model} <- model(json["model"]),
         {:ok, selectors} <- each(json["selectors"], &selector(&1, model)),
         :ok <- unique(Enum.map(selectors, & &1.name)) do
      {:ok, %__MODULE__{endpoint: endpoint, unit_id: unit, model: model, selectors: selectors}}
    end
  end

  @doc "The values an owed restore puts back, as what was left once it is read back."
  @spec left(t()) :: left()
  def left(%__MODULE__{unit_id: unit, model: model, selectors: selectors}),
    do: Map.new(selectors, &{{unit, model, &1.name}, &1.value})

  @spec encode_left(endpoint(), left()) :: String.t()
  def encode_left(endpoint, left) do
    selectors =
      left
      |> Enum.sort()
      |> Enum.map(fn {{unit, model, name}, value} ->
        %{"unit_id" => unit, "model" => model, "name" => Atom.to_string(name), "value" => value}
      end)

    JSON.encode!(%{
      "format" => @left,
      "endpoint" => endpoint_json(endpoint),
      "selectors" => selectors
    })
  end

  # contract: test/alavi/selectors/record_test.exs "parse_left/2"
  @spec parse_left(binary(), endpoint()) :: {:ok, left()} | {:error, String.t()}
  def parse_left(text, endpoint) do
    with {:ok, json} <- decode(text),
         :ok <- header(json, @left, endpoint, []),
         {:ok, entries} <- each(json["selectors"], &left_entry/1, :empty_allowed),
         :ok <- unique(Enum.map(entries, &elem(&1, 0))) do
      {:ok, Map.new(entries)}
    end
  end

  defp decode(text) do
    case JSON.decode(text) do
      {:ok, json} when is_map(json) -> {:ok, json}
      {:ok, _other} -> {:error, "not a JSON object"}
      {:error, reason} -> {:error, "invalid JSON (#{inspect(reason)})"}
    end
  end

  defp header(%{"format" => format, "endpoint" => ep} = json, format, endpoint, keys) do
    expected = endpoint_json(endpoint)
    unknown = Map.keys(json) -- (["format", "endpoint", "selectors"] ++ keys)

    cond do
      ep != expected -> {:error, "names endpoint #{inspect(ep)}, not #{inspect(expected)}"}
      unknown != [] -> {:error, "unknown fields #{inspect(unknown)}"}
      true -> :ok
    end
  end

  defp header(%{"format" => format}, expected, _endpoint, _keys),
    do: {:error, "format #{inspect(format)}, not #{expected}"}

  defp header(_json, expected, _endpoint, _keys), do: {:error, "no format; expected #{expected}"}

  defp endpoint_json(%{host: host, port: port}), do: %{"host" => host, "port" => port}

  defp unit(unit) when unit in 1..247, do: {:ok, unit}
  defp unit(unit), do: {:error, "unit_id #{inspect(unit)} is not 1..247"}

  defp model(model) when is_binary(model) do
    if Enum.any?(Selector.allowlist(), &(&1.model == model)),
      do: {:ok, model},
      else: {:error, "model #{inspect(model)} has no selectors"}
  end

  defp model(model), do: {:error, "model #{inspect(model)} is not a string"}

  defp selector(%{"name" => name, "value" => value, "bound" => bound} = s, model)
       when map_size(s) == 3 and is_integer(bound) do
    with {:ok, name} <- name(model, name),
         {:ok, value} <- value(value),
         do: {:ok, %{name: name, value: value, bound: bound}}
  end

  defp selector(s, _model), do: {:error, "selector #{inspect(s)} is not name, value and bound"}

  defp left_entry(%{"unit_id" => unit, "model" => model, "name" => name, "value" => value} = e)
       when map_size(e) == 4 do
    with {:ok, unit} <- unit(unit),
         {:ok, model} <- model(model),
         {:ok, name} <- name(model, name),
         {:ok, value} <- value(value),
         do: {:ok, {{unit, model, name}, value}}
  end

  defp left_entry(e), do: {:error, "entry #{inspect(e)} is not unit_id, model, name and value"}

  # Names are matched against the allowlist's atoms: text from disk never becomes an atom.
  defp name(model, name) do
    case Enum.find(Selector.allowlist(), &(&1.model == model and Atom.to_string(&1.name) == name)) do
      nil -> {:error, "#{inspect(name)} is not a selector of #{model}"}
      entry -> {:ok, entry.name}
    end
  end

  defp value(value) when value in 0..0xFFFF, do: {:ok, value}
  defp value(value), do: {:error, "value #{inspect(value)} is not a register word"}

  defp each(items, parse, empty \\ :non_empty)
  defp each([], _parse, :non_empty), do: {:error, "no selectors"}

  defp each(items, parse, _empty) when is_list(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case parse.(item) do
        {:ok, parsed} -> {:cont, {:ok, acc ++ [parsed]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp each(items, _parse, _empty), do: {:error, "selectors #{inspect(items)} is not a list"}

  defp unique(keys) do
    if Enum.uniq(keys) == keys, do: :ok, else: {:error, "a selector is listed twice"}
  end
end
