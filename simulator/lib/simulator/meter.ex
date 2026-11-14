defmodule Simulator.Meter do
  @moduledoc """
  One simulated meter on a chain. `word_order` overrides the profile's, to
  simulate a meter configured differently from its manual.

  `identity` overrides, per check, what the profile's identity registers hold:
  a product code, a serial, an energy unit code, or `:absent` to leave the
  register unmapped (exception 02), as on a meter with no unit setting. A new
  meter's serial is `SIM-<unit_id>`, an invented value.

  `firmware` holds what the profile's name registers report, per name, or
  `:absent` to unmap them. A new meter's names are invented too (`SIM-SW`,
  `SIM-F1`, `SIM-F2`, version `0100`); the version is the hex digits of its
  word.

  `selectors` holds the selector registers a profile's meter lets a client
  write, by PDU address, each starting at 0: the stored history, snapshot and
  load-survey day and parameter to show. A write of one, with the model's own
  function code (06 on the Elite 440 family, 16 on the Elite 500), is echoed
  and the register reads back the new value. Any other address is exception 02.
  The 440 family answers 16 with exception 02 and the 500 answers 06 with
  exception 01, as real meters do. Values are not range-checked: what a meter
  does with one out of range is not known.
  """

  alias Simulator.{Encode, Profile}

  @enforce_keys [:unit_id, :profile, :values]
  defstruct [
    :unit_id,
    :profile,
    :values,
    word_order: nil,
    identity: %{},
    firmware: %{},
    selectors: %{}
  ]

  @type check :: :product_code | :serial | :energy_unit
  @type t :: %__MODULE__{
          unit_id: 1..247,
          profile: Profile.t(),
          values: %{String.t() => Decimal.t()},
          word_order: :high_first | :low_first | nil,
          identity: %{optional(check()) => String.t() | 0..0xFFFF | :absent},
          firmware: %{optional(Profile.firmware_name()) => String.t() | :absent},
          selectors: %{optional(0..0xFFFF) => 0..0xFFFF}
        }

  @type write_code :: 6 | 16

  @names %{
    software: "SIM-SW",
    firmware_1: "SIM-F1",
    firmware_2: "SIM-F2",
    modbus_version: "0100"
  }

  # Selector PDU addresses (register number − 40001), source IDs elite_440-a
  # and elite_500-a: history, snapshot, load-survey parameter and day (440);
  # history, snapshot, load-survey day and parameter (500).
  @selectors %{
    "elite_440" => %{function_code: 6, other: {16, 2}, addresses: [520, 700, 800, 801]},
    "elite_500" => %{function_code: 16, other: {6, 1}, addresses: [900, 1500, 5002, 5003]}
  }

  @doc "A meter whose registers all start at zero, then take `values`."
  @spec new(1..247, Profile.t(), %{String.t() => Decimal.t()}) :: t()
  def new(unit_id, %Profile{} = profile, values \\ %{}) do
    zeros = Map.new(profile.registers, fn {key, _} -> {key, Decimal.new(0)} end)

    %__MODULE__{
      unit_id: unit_id,
      profile: profile,
      values: Map.merge(zeros, values),
      identity: %{serial: "SIM-#{unit_id}"},
      firmware: @names,
      selectors: selectors(profile)
    }
  end

  defp selectors(%Profile{name: name}) do
    case @selectors do
      %{^name => %{addresses: addresses}} -> Map.new(addresses, &{&1, 0})
      _ -> %{}
    end
  end

  # contract: test/simulator/meter_test.exs "write/4"
  @doc """
  Write one selector register, as function code `function_code`. Anything
  but a selector write this model takes is the exception code a meter answers.
  """
  @spec write(t(), write_code(), 0..0xFFFF, 0..0xFFFF) :: {:ok, t()} | {:exception, 1..2}
  def write(
        %__MODULE__{profile: %Profile{name: name}, selectors: selectors} = meter,
        fc,
        address,
        value
      ) do
    case @selectors do
      %{^name => %{function_code: ^fc}} when is_map_key(selectors, address) ->
        {:ok, %{meter | selectors: Map.put(selectors, address, value)}}

      %{^name => %{function_code: ^fc}} ->
        {:exception, 2}

      %{^name => %{other: {^fc, code}}} ->
        {:exception, code}

      _ ->
        {:exception, 1}
    end
  end

  @doc "Set a selector this meter has, by PDU address, whatever any client asked."
  @spec select(t(), 0..0xFFFF, 0..0xFFFF) :: t()
  def select(%__MODULE__{selectors: selectors} = meter, address, value)
      when is_map_key(selectors, address),
      do: %{meter | selectors: Map.put(selectors, address, value)}

  @doc "Set one register's value."
  @spec put(t(), String.t(), Decimal.t()) :: t()
  def put(%__MODULE__{values: values} = meter, key, value) when is_map_key(values, key),
    do: %{meter | values: Map.put(values, key, value)}

  @doc "Override what the meter reports for one identity check (`:absent` unmaps it)."
  @spec identify(t(), check(), String.t() | 0..0xFFFF | :absent) :: t()
  def identify(%__MODULE__{identity: identity} = meter, check, value)
      when check in [:product_code, :serial, :energy_unit],
      do: %{meter | identity: Map.put(identity, check, value)}

  @doc "Override what the meter reports for one name (`:absent` unmaps it)."
  @spec name(t(), Profile.firmware_name(), String.t() | :absent) :: t()
  def name(%__MODULE__{firmware: firmware} = meter, name, value) when is_map_key(@names, name),
    do: %{meter | firmware: Map.put(firmware, name, value)}

  @doc "The words at `count` consecutive addresses, or `:unmapped` if any address holds nothing."
  @spec read(t(), Profile.table(), 0..0xFFFF, pos_integer()) :: {:ok, [0..0xFFFF]} | :unmapped
  def read(meter, table, address, count) do
    bank = bank(meter, table)
    words = Enum.map(address..(address + count - 1)//1, &Map.get(bank, &1))
    if Enum.any?(words, &is_nil/1), do: :unmapped, else: {:ok, words}
  end

  defp bank(%__MODULE__{profile: profile, values: values, word_order: override} = meter, table) do
    registers =
      for {key, %{table: ^table} = spec} <- profile.registers,
          {word, offset} <- Enum.with_index(Encode.words(order(spec, override), values[key])),
          into: %{},
          do: {spec.address + offset, word}

    registers
    |> Map.merge(identity_bank(meter, table))
    |> Map.merge(firmware_bank(meter, table))
    |> Map.merge(selector_bank(meter, table))
  end

  defp selector_bank(%__MODULE__{selectors: selectors}, :holding), do: selectors
  defp selector_bank(_meter, :input), do: %{}

  defp firmware_bank(%__MODULE__{profile: profile, firmware: names}, table) do
    for {name, %{table: ^table} = spec} <- profile.firmware,
        value = Map.fetch!(names, name),
        value != :absent,
        {word, offset} <- Enum.with_index(name_words(spec, value)),
        into: %{},
        do: {spec.address + offset, word}
  end

  defp name_words(%{type: :ascii, count: count}, text), do: text_words(text, count)
  defp name_words(%{type: :hex}, digits), do: for(<<w::16 <- Base.decode16!(digits)>>, do: w)

  defp identity_bank(%__MODULE__{profile: profile, identity: overrides}, table) do
    for {check, %{table: ^table} = spec} <- profile.identity,
        value = Map.get_lazy(overrides, check, fn -> spec.value end),
        value != :absent,
        {word, offset} <- Enum.with_index(identity_words(check, spec, value)),
        into: %{},
        do: {spec.address + offset, word}
  end

  defp identity_words(check, %{count: count}, text) when check in [:product_code, :serial],
    do: text_words(text, count)

  defp identity_words(:energy_unit, %{part: :high_byte}, code), do: [Bitwise.bsl(code, 8)]
  defp identity_words(:energy_unit, %{part: :word}, code), do: [code]

  defp text_words(text, count) do
    padded = String.pad_trailing(text, count * 2, <<0>>)
    for <<word::16 <- binary_part(padded, 0, count * 2)>>, do: word
  end

  defp order(spec, nil), do: spec
  defp order(spec, word_order), do: %{spec | word_order: word_order}
end
