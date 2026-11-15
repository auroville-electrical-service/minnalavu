defmodule Alavi.Config.Fields do
  @moduledoc false
  # None of these supplies a default.

  @type result(t) :: {:ok, t} | {:error, String.t()}

  @spec only(map(), [String.t()]) :: :ok | {:error, String.t()}
  def only(map, allowed) do
    case Map.keys(map) -- allowed do
      [] -> :ok
      unknown -> {:error, "unknown field(s) #{Enum.join(Enum.sort(unknown), ", ")}"}
    end
  end

  @spec string(map(), String.t()) :: result(String.t())
  def string(map, field) do
    case Map.fetch(map, field) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "#{field} must be a non-empty string"}
    end
  end

  # JSON Schema's `$` ends the string; PCRE's would also match before a final
  # newline, hence :dollar_endonly.
  @spec matching(map(), String.t(), String.t(), String.t()) :: result(String.t())
  def matching(map, field, pattern, rule) do
    with {:ok, value} <- string(map, field) do
      if Regex.match?(Regex.compile!(pattern, [:unicode, :ucp, :dollar_endonly]), value),
        do: {:ok, value},
        else: {:error, "#{field} #{inspect(value)} is not #{rule}"}
    end
  end

  @spec integer(map(), String.t(), Range.t()) :: result(integer())
  def integer(map, field, first..last//_) do
    case Map.fetch(map, field) do
      {:ok, value} when is_integer(value) and value >= first and value <= last -> {:ok, value}
      _ -> {:error, "#{field} must be an integer in #{first}..#{last}"}
    end
  end

  @spec positive(map(), String.t()) :: result(pos_integer())
  def positive(map, field) do
    case Map.fetch(map, field) do
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, "#{field} must be a positive integer"}
    end
  end

  @spec boolean(map(), String.t()) :: result(boolean())
  def boolean(map, field) do
    case Map.fetch(map, field) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      _ -> {:error, "#{field} must be true or false"}
    end
  end

  @spec lookup(map(), String.t(), %{String.t() => value}) :: result(value) when value: term()
  def lookup(map, field, known) do
    case Map.fetch(map, field) do
      {:ok, name} when is_map_key(known, name) -> {:ok, Map.fetch!(known, name)}
      _ -> {:error, "#{field} must be one of #{known |> Map.keys() |> Enum.join(", ")}"}
    end
  end

  # contract: test/alavi/config_test.exs "parse/2"
  @spec each(map(), String.t(), (term() -> result(t))) :: result([t, ...]) when t: term()
  def each(map, field, parse) do
    case Map.fetch(map, field) do
      {:ok, [_ | _] = entries} -> entries |> Enum.with_index() |> parse_all(field, parse)
      _ -> {:error, "#{field} must be a non-empty list"}
    end
  end

  # contract: test/alavi/config_test.exs "parse/2"
  @spec unique([t], (t -> term()), String.t()) :: :ok | {:error, String.t()} when t: term()
  def unique(items, key, what) do
    case items |> Enum.frequencies_by(key) |> Enum.find(fn {_, n} -> n > 1 end) do
      nil -> :ok
      {repeated, _} -> {:error, "#{what} #{format(repeated)} appears more than once"}
    end
  end

  defp parse_all(indexed, field, parse) do
    indexed
    |> Enum.reduce_while([], fn {entry, index}, acc ->
      case parse.(entry) do
        {:ok, value} -> {:cont, [value | acc]}
        {:error, reason} -> {:halt, {:error, "#{field}[#{index}]: #{reason}"}}
      end
    end)
    |> then(fn
      {:error, _} = error -> error
      values -> {:ok, Enum.reverse(values)}
    end)
  end

  defp format({host, port}), do: "#{host}:#{port}"
  defp format(value), do: inspect(value)
end
