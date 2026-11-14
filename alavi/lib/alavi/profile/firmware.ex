defmodule Alavi.Profile.Firmware do
  @moduledoc """
  Where a meter reports its software and firmware names, parsed from a
  profile's `firmware` section. Informational only: nothing here gates a read
  or labels a reading. Pure: `reads/1` lists what to read and `decode/2` turns
  what came back into the text sent on.
  """

  alias Alavi.Config.Fields
  alias Alavi.Modbus.PDU
  alias Alavi.Profile.{Register, Text}

  @enforce_keys [:software, :firmware_1, :firmware_2, :modbus_version]
  defstruct @enforce_keys

  @typedoc """
  `:ascii` is text, as the serial is read. `:hex` is each byte as two
  uppercase hex digits, high byte first: the version word 0x0B03 is "0B03".
  """
  @type kind :: :ascii | :hex
  @type entry :: %{
          table: PDU.table(),
          address: 0..0xFFFF,
          count: 1..125,
          type: kind(),
          source: Register.source(),
          verified_on_device: Date.t() | nil
        }
  @type t :: %__MODULE__{
          software: entry(),
          firmware_1: entry(),
          firmware_2: entry(),
          modbus_version: entry()
        }
  @type name :: :software | :firmware_1 | :firmware_2 | :modbus_version
  @type read :: {name(), PDU.table(), 0..0xFFFF, 1..125}
  @type error :: :wrong_word_count | :empty | :not_printable

  @names [:software, :firmware_1, :firmware_2, :modbus_version]
  @fields Map.new(@names, &{Atom.to_string(&1), &1})
  @tables %{"holding" => :holding, "input" => :input}
  @kinds %{"ascii" => :ascii, "hex" => :hex}

  # contract: test/alavi/profile/firmware_test.exs "parse/1"
  @spec parse(term()) :: {:ok, t()} | {:error, String.t()}
  def parse(%{} = json) do
    with :ok <- Fields.only(json, Map.keys(@fields)),
         {:ok, entries} <- entries(json) do
      {:ok, struct!(__MODULE__, entries)}
    end
  end

  def parse(_json), do: {:error, "firmware must be an object"}

  @spec sources(t()) :: [Register.source()]
  def sources(%__MODULE__{} = firmware),
    do: for(name <- @names, do: Map.fetch!(firmware, name).source)

  # contract: test/alavi/profile/firmware_test.exs "reads/1"
  @spec reads(t()) :: [read()]
  def reads(%__MODULE__{} = firmware) do
    for name <- @names,
        %{table: table, address: address, count: count} = Map.fetch!(firmware, name),
        do: {name, table, address, count}
  end

  # contract: test/alavi/profile/firmware_test.exs "decode/2"
  @doc "`words` are in register-address order, as read from the meter."
  @spec decode(entry(), [0..0xFFFF]) :: {:ok, String.t()} | {:error, error()}
  def decode(%{count: count}, words) when length(words) != count,
    do: {:error, :wrong_word_count}

  def decode(%{type: :hex}, words),
    do: {:ok, words |> Enum.map_join(&<<&1::16>>) |> Base.encode16()}

  def decode(%{type: :ascii}, words) do
    case Text.trimmed(words) do
      "" -> {:error, :empty}
      text -> if(Text.printable(text), do: {:ok, text}, else: {:error, :not_printable})
    end
  end

  defp entries(json) do
    Enum.reduce_while(@fields, {:ok, %{}}, fn {field, name}, {:ok, acc} ->
      case entry(json, field) do
        {:ok, entry} -> {:cont, {:ok, Map.put(acc, name, entry)}}
        {:error, reason} -> {:halt, {:error, "firmware.#{field}: #{reason}"}}
      end
    end)
  end

  defp entry(json, field) do
    case Map.fetch(json, field) do
      {:ok, %{} = entry} -> located(entry)
      {:ok, _} -> {:error, "must be an object"}
      :error -> {:error, "is missing"}
    end
  end

  defp located(json) do
    with :ok <- Fields.only(json, ~w(table address count type source verified_on_device)),
         {:ok, table} <- Fields.lookup(json, "table", @tables),
         {:ok, address} <- Fields.integer(json, "address", 0..0xFFFF),
         {:ok, count} <- Fields.integer(json, "count", 1..125),
         {:ok, type} <- Fields.lookup(json, "type", @kinds),
         {:ok, source} <- Register.parse_source(json["source"]),
         {:ok, verified} <- Register.parse_verified(json) do
      {:ok,
       %{
         table: table,
         address: address,
         count: count,
         type: type,
         source: source,
         verified_on_device: verified
       }}
    end
  end
end
