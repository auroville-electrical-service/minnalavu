defmodule Simulator.Profile do
  @moduledoc """
  The parts of a `contract/profiles/*.json` register map the simulator needs.
  Parsed independently of `alavi`, so the two sides cross-check each other.
  """

  @enforce_keys [:name, :registers, :identity, :firmware]
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
  @type t :: %__MODULE__{
          name: String.t(),
          registers: %{String.t() => spec()},
          identity: identity(),
          firmware: firmware()
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
      firmware: json |> Map.get("firmware", %{}) |> Map.new(&firmware_spec/1)
    }
  end

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
