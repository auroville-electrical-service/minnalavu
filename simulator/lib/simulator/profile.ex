defmodule Simulator.Profile do
  @moduledoc """
  The parts of a `contract/profiles/*.json` register map the simulator needs.
  Parsed independently of `alavi`, so the two sides cross-check each other.
  """

  @enforce_keys [:name, :registers, :identity, :firmware, :meter_clock, :stored]
  defstruct @enforce_keys

  @type table :: :holding | :input
  @typedoc "`decimals` is nil for a float type: a profile gives none."
  @type spec :: %{
          table: table(),
          address: 0..0xFFFF,
          type: :u16 | :i16 | :u32 | :i32 | :u64 | :f32 | :f64,
          word_order: :high_first | :low_first,
          decimals: 0..9 | nil
        }
  @typedoc """
  The identity registers a meter of this profile answers, by check: where they
  are and what a matching meter holds there (the first accepted product code,
  the expected energy unit code). A serial has no profile value: each meter
  has its own (`Simulator.Meter`).
  """
  @type identity :: %{
          optional(:product_code) => %{
            table: table(),
            address: 0..0xFFFF,
            count: pos_integer(),
            value: String.t()
          },
          optional(:serial) => %{table: table(), address: 0..0xFFFF, count: pos_integer()},
          optional(:energy_unit) => %{
            table: table(),
            address: 0..0xFFFF,
            part: :high_byte | :word,
            value: 0..0xFFFF
          }
        }
  @type firmware_name :: :software | :firmware_1 | :firmware_2 | :modbus_version
  @typedoc """
  Where a meter of this profile reports its names, empty where the profile has
  no `firmware` section. The names have no profile value: each meter has its
  own (`Simulator.Meter`).
  """
  @type firmware :: %{
          optional(firmware_name()) => %{
            table: table(),
            address: 0..0xFFFF,
            count: pos_integer(),
            type: :ascii | :hex
          }
        }
  @type order :: :high_first | :low_first
  @typedoc "A u32 count of seconds since `epoch`, by the meter's own clock."
  @type stamp :: %{address: 0..0xFFFF, word_order: order(), epoch: NaiveDateTime.t()}
  @type mask :: %{address: 0..0xFFFF, type: :u16 | :u32 | :u64, word_order: order()}
  @type stored_register :: %{
          key: String.t(),
          address: 0..0xFFFF,
          word_order: order(),
          mask_bit: non_neg_integer() | nil
        }
  @typedoc "A history or snapshot store: every address in it is a holding register."
  @type block :: %{
          available: 0..0xFFFF,
          stamp: stamp(),
          mask: mask() | nil,
          registers: [stored_register()]
        }
  @type kind :: :interval | :instantaneous | :demand
  @type survey :: %{
          available: 0..0xFFFF,
          interval: 0..0xFFFF,
          stamp: stamp(),
          mask: mask(),
          values: %{address: 0..0xFFFF, word_order: order()},
          parameters: [
            %{number: non_neg_integer(), key: String.t(), unit: String.t(), kind: kind()}
          ]
        }
  @type stored :: %{history: block(), snapshot: block(), load_survey: survey()}
  @typedoc "`meter_clock` and `stored` are nil for a profile without them."
  @type t :: %__MODULE__{
          name: String.t(),
          registers: %{String.t() => spec()},
          identity: identity(),
          firmware: firmware(),
          meter_clock: stamp() | nil,
          stored: stored() | nil
        }

  @doc "The repo's shared profile directory."
  @spec dir() :: Path.t()
  def dir, do: Path.expand("../../../contract/profiles", __DIR__)

  @doc "Load profile `name` from `dir`."
  @spec load!(String.t(), Path.t()) :: t()
  def load!(name, dir \\ dir()) do
    json = dir |> Path.join("#{name}.json") |> File.read!() |> JSON.decode!()
    %{"profile" => ^name, "registers" => entries, "identity" => identity} = json

    %__MODULE__{
      name: name,
      registers: Map.new(entries, &spec/1),
      identity: Map.new(identity, &identity_spec/1),
      firmware: json |> Map.get("firmware", %{}) |> Map.new(&firmware_spec/1),
      meter_clock: json |> Map.get("meter_clock") |> optional(&stamp/1),
      stored: json |> Map.get("stored") |> optional(&stored/1)
    }
  end

  defp optional(nil, _parse), do: nil
  defp optional(entry, parse), do: parse.(entry)

  defp stored(%{"history" => history, "snapshot" => snapshot, "load_survey" => survey}),
    do: %{history: block(history), snapshot: block(snapshot), load_survey: survey(survey)}

  defp block(%{"available" => available, "stamp" => stamp, "registers" => registers} = entry) do
    %{
      available: holding(available),
      stamp: stamp(stamp),
      mask: entry |> Map.get("mask") |> optional(&mask/1),
      registers: Enum.map(registers, &stored_register/1)
    }
  end

  defp survey(entry) do
    %{"values" => %{"type" => "f32"} = values, "parameters" => parameters} = entry

    %{
      available: holding(entry["available"]),
      interval: holding(entry["interval"]),
      stamp: stamp(entry["stamp"]),
      mask: mask(entry["mask"]),
      values: %{address: holding(values), word_order: word_order(values["word_order"])},
      parameters: Enum.map(parameters, &parameter/1)
    }
  end

  defp stored_register(%{"type" => "f32"} = entry) do
    %{
      key: entry["key"],
      address: holding(entry),
      word_order: word_order(entry["word_order"]),
      mask_bit: Map.get(entry, "mask_bit")
    }
  end

  defp parameter(entry) do
    %{number: entry["number"], key: entry["key"], unit: entry["unit"], kind: kind(entry["kind"])}
  end

  defp stamp(%{"type" => "u32"} = entry) do
    %{
      address: holding(entry),
      word_order: word_order(entry["word_order"]),
      epoch: NaiveDateTime.from_iso8601!(entry["epoch"])
    }
  end

  # A one-word mask has no word order.
  defp mask(%{"type" => "u16"} = entry),
    do: %{address: holding(entry), type: :u16, word_order: :high_first}

  defp mask(entry) do
    %{
      address: holding(entry),
      type: type(entry["type"]),
      word_order: word_order(entry["word_order"])
    }
  end

  defp holding(%{"table" => "holding", "address" => address}), do: address

  defp kind("interval"), do: :interval
  defp kind("instantaneous"), do: :instantaneous
  defp kind("demand"), do: :demand

  defp spec(entry) do
    {entry["key"],
     %{
       table: table(entry["table"]),
       address: entry["address"],
       type: type(entry["type"]),
       word_order: word_order(entry["word_order"]),
       decimals: Map.get(entry, "decimals")
     }}
  end

  defp identity_spec({"product_code", entry}) do
    {:product_code,
     %{
       table: table(entry["table"]),
       address: entry["address"],
       count: entry["count"],
       value: hd(entry["accept"])
     }}
  end

  defp identity_spec({"serial", entry}) do
    {:serial, %{table: table(entry["table"]), address: entry["address"], count: entry["count"]}}
  end

  defp identity_spec({"energy_unit", entry}) do
    {:energy_unit,
     %{
       table: table(entry["table"]),
       address: entry["address"],
       part: part(entry["part"]),
       value: entry["expect"]
     }}
  end

  defp firmware_spec({name, entry}) do
    {firmware_name(name),
     %{
       table: table(entry["table"]),
       address: entry["address"],
       count: entry["count"],
       type: firmware_type(entry["type"])
     }}
  end

  defp firmware_name("software"), do: :software
  defp firmware_name("firmware_1"), do: :firmware_1
  defp firmware_name("firmware_2"), do: :firmware_2
  defp firmware_name("modbus_version"), do: :modbus_version

  defp firmware_type("ascii"), do: :ascii
  defp firmware_type("hex"), do: :hex

  defp part("high_byte"), do: :high_byte
  defp part("word"), do: :word

  defp table("holding"), do: :holding
  defp table("input"), do: :input

  defp type("u16"), do: :u16
  defp type("i16"), do: :i16
  defp type("u32"), do: :u32
  defp type("i32"), do: :i32
  defp type("u64"), do: :u64
  defp type("f32"), do: :f32
  defp type("f64"), do: :f64

  defp word_order("high_first"), do: :high_first
  defp word_order("low_first"), do: :low_first
end
