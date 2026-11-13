defmodule Alavi.Profile.Register do
  alias Alavi.Modbus.PDU

  @enforce_keys [
    :key,
    :table,
    :address,
    :type,
    :word_order,
    :decimals,
    :unit,
    :source,
    :placeholder,
    :verified_on_device
  ]
  defstruct @enforce_keys

  @type data_type :: :u16 | :i16 | :u32 | :i32 | :u64 | :f32 | :f64
  @type word_order :: :high_first | :low_first
  @type source :: String.t()

  @type t :: %__MODULE__{
          key: String.t(),
          table: PDU.table(),
          address: 0..0xFFFF,
          type: data_type(),
          word_order: word_order(),
          decimals: 0..9,
          unit: String.t(),
          source: source() | nil,
          placeholder: boolean(),
          verified_on_device: Date.t() | nil
        }

  @tables %{"holding" => :holding, "input" => :input}
  @types %{
    "u16" => :u16,
    "i16" => :i16,
    "u32" => :u32,
    "i32" => :i32,
    "u64" => :u64,
    "f32" => :f32,
    "f64" => :f64
  }
  @word_orders %{"high_first" => :high_first, "low_first" => :low_first}
  @units ["Wh", "kWh", "varh", "kvarh"]

  @spec word_count(t() | data_type()) :: 1 | 2 | 4
  def word_count(%__MODULE__{type: type}), do: word_count(type)
  def word_count(type) when type in [:u16, :i16], do: 1
  def word_count(type) when type in [:u32, :i32, :f32], do: 2
  def word_count(type) when type in [:u64, :f64], do: 4

  # contract: test/alavi/profile_test.exs "parse/1"
  @spec parse(map()) :: {:ok, t()} | {:error, String.t()}
  def parse(entry) when is_map(entry) do
    with {:ok, key} <- string(entry, "key"),
         {:ok, table} <- lookup(entry, "table", @tables),
         {:ok, address} <- integer(entry, "address", 0..0xFFFF),
         {:ok, type} <- lookup(entry, "type", @types),
         {:ok, word_order} <- lookup(entry, "word_order", @word_orders),
         {:ok, decimals} <- integer(entry, "decimals", 0..9),
         {:ok, unit} <- one_of(entry, "unit", @units),
         {:ok, placeholder} <- boolean(entry, "placeholder"),
         {:ok, verified} <- parse_verified(entry),
         {:ok, source} <- source(entry, placeholder) do
      {:ok,
       %__MODULE__{
         key: key,
         table: table,
         address: address,
         type: type,
         word_order: word_order,
         decimals: decimals,
         unit: unit,
         source: source,
         placeholder: placeholder,
         verified_on_device: verified
       }}
    end
  end

  def parse(_entry), do: {:error, "register entry is not an object"}

  # contract: test/alavi/profile_test.exs "parse/1"
  @spec parse_source(term()) :: {:ok, source()} | {:error, String.t()}
  def parse_source(id) when is_binary(id) do
    if id =~ ~r/\A[a-z0-9][a-z0-9_-]*\z/,
      do: {:ok, id},
      else: {:error, "source #{inspect(id)} must be lowercase letters, digits, - and _"}
  end

  def parse_source(_id), do: {:error, "source must be a source ID"}

  @spec parse_verified(map()) :: {:ok, Date.t() | nil} | {:error, String.t()}
  def parse_verified(%{"verified_on_device" => nil}), do: {:ok, nil}

  def parse_verified(%{"verified_on_device" => date}) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, day} -> {:ok, day}
      {:error, _} -> parse_verified(%{})
    end
  end

  def parse_verified(_entry),
    do: {:error, "verified_on_device must be null or a YYYY-MM-DD date"}

  defp source(%{"source" => nil}, true), do: {:ok, nil}

  defp source(%{"source" => nil}, false),
    do: {:error, "source is null but the entry is not marked placeholder"}

  defp source(%{"source" => id}, _placeholder), do: parse_source(id)
  defp source(_entry, _placeholder), do: {:error, "source must be a source ID or null"}

  defp string(map, field) do
    case Map.fetch(map, field) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "#{field} must be a non-empty string"}
    end
  end

  defp integer(map, field, range) do
    case Map.fetch(map, field) do
      {:ok, value} when is_integer(value) -> in_range(value, field, range)
      _ -> {:error, "#{field} must be an integer"}
    end
  end

  defp in_range(value, field, first..last//_ = range) do
    if value in range, do: {:ok, value}, else: {:error, "#{field} must be in #{first}..#{last}"}
  end

  defp boolean(map, field) do
    case Map.fetch(map, field) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      _ -> {:error, "#{field} must be true or false"}
    end
  end

  defp lookup(map, field, known) do
    with {:ok, name} <- one_of(map, field, Map.keys(known)), do: {:ok, Map.fetch!(known, name)}
  end

  defp one_of(map, field, allowed) do
    case Map.fetch(map, field) do
      {:ok, value} when is_binary(value) ->
        if value in allowed,
          do: {:ok, value},
          else: {:error, "#{field} #{inspect(value)} unknown"}

      _ ->
        {:error, "#{field} must be one of #{Enum.join(allowed, ", ")}"}
    end
  end
end
