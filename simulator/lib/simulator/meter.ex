defmodule Simulator.Meter do
  @moduledoc """
  One simulated meter on a chain. `word_order` overrides the profile's, to
  simulate a meter configured differently from its manual.

  `identity` overrides, per check, what the profile's identity registers hold:
  a product code, a serial, an energy unit code, or `:absent` to leave the
  register unmapped (exception 02), as on a meter with no unit setting. A new
  meter's serial is `SIM-<unit_id>`, an invented value.
  """

  alias Simulator.{Encode, Profile}

  @enforce_keys [:unit_id, :profile, :values]
  defstruct [:unit_id, :profile, :values, word_order: nil, identity: %{}]

  @type check :: :product_code | :serial | :energy_unit
  @type t :: %__MODULE__{
          unit_id: 1..247,
          profile: Profile.t(),
          values: %{String.t() => Decimal.t()},
          word_order: :high_first | :low_first | nil,
          identity: %{optional(check()) => String.t() | 0..0xFFFF | :absent}
        }

  @doc "A meter whose registers all start at zero, then take `values`."
  @spec new(1..247, Profile.t(), %{String.t() => Decimal.t()}) :: t()
  def new(unit_id, %Profile{} = profile, values \\ %{}) do
    zeros = Map.new(profile.registers, fn {key, _} -> {key, Decimal.new(0)} end)

    %__MODULE__{
      unit_id: unit_id,
      profile: profile,
      values: Map.merge(zeros, values),
      identity: %{serial: "SIM-#{unit_id}"}
    }
  end

  @doc "Set one register's value."
  @spec put(t(), String.t(), Decimal.t()) :: t()
  def put(%__MODULE__{values: values} = meter, key, value) when is_map_key(values, key),
    do: %{meter | values: Map.put(values, key, value)}

  @doc "Override what the meter reports for one identity check (`:absent` unmaps it)."
  @spec identify(t(), check(), String.t() | 0..0xFFFF | :absent) :: t()
  def identify(%__MODULE__{identity: identity} = meter, check, value)
      when check in [:product_code, :serial, :energy_unit],
      do: %{meter | identity: Map.put(identity, check, value)}

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

    Map.merge(registers, identity_bank(meter, table))
  end

  defp identity_bank(%__MODULE__{profile: profile, identity: overrides}, table) do
    for {check, %{table: ^table} = spec} <- profile.identity,
        value = Map.get_lazy(overrides, check, fn -> spec.value end),
        value != :absent,
        {word, offset} <- Enum.with_index(identity_words(check, spec, value)),
        into: %{},
        do: {spec.address + offset, word}
  end

  defp identity_words(check, %{count: count}, text) when check in [:product_code, :serial] do
    padded = String.pad_trailing(text, count * 2, <<0>>)
    for <<word::16 <- binary_part(padded, 0, count * 2)>>, do: word
  end

  defp identity_words(:energy_unit, %{part: :high_byte}, code), do: [Bitwise.bsl(code, 8)]
  defp identity_words(:energy_unit, %{part: :word}, code), do: [code]

  defp order(spec, nil), do: spec
  defp order(spec, word_order), do: %{spec | word_order: word_order}
end
