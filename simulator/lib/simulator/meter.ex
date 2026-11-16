defmodule Simulator.Meter do
  @moduledoc """
  One simulated meter on a chain. `word_order` overrides the profile's, to
  simulate a meter configured differently from its manual.

  `identity` overrides, per check, what the profile's identity registers hold:
  a product code, a serial, an energy unit code, or `:absent` to leave the
  register unmapped (exception 02), as on a meter with no unit setting. A new
  meter's serial is `SIM-<unit_id>`, an invented value.

  Each model's identity block answers as one request, as the real meters do:
  holding 0-35 on the Elite 440 family, 1999-2026 on the Elite 500. Registers
  in it the simulator does not model read 0. A register left `:absent` is
  unmapped in the block too, so a request across it is refused whole.

  `firmware` holds what the profile's name registers report, per name, or
  `:absent` to unmap them. A new meter's names are invented too (`SIM-SW`,
  `SIM-F1`, `SIM-F2`, version `0100`); the version is the hex digits of its
  word.

  `selectors` holds the selector registers a profile's meter lets a client
  write, by PDU address, each starting at 0: the stored history, snapshot and
  load-survey day and parameter to show (`Simulator.Stores`). A write of one,
  with the model's own function code (06 on the Elite 440 family, 16 on the
  Elite 500), is echoed and the register reads back the new value. Any other
  address is exception 02, and a value naming an entry the meter does not
  hold, or a parameter it does not support, exception 03. The 440 family
  answers 16 with exception 02 and the 500 answers 06 with exception 01, as
  real meters do. On the 500 the load survey shows the new day or parameter
  only 100 ms after the write; until then it shows the previous selection's.

  `clock` is the meter's own clock: the host's (UTC, read as the meter's
  local time) plus `offset_s`, gaining `drift_ppm` millionths from the host
  time the meter was anchored at, which `Simulator` does when it starts.
  """

  alias Simulator.{Encode, Profile, Stores}

  @enforce_keys [:unit_id, :profile, :values, :stores]
  defstruct [
    :unit_id,
    :profile,
    :values,
    :stores,
    word_order: nil,
    identity: %{},
    firmware: %{},
    selectors: %{},
    settling: %{},
    clock: %{offset_s: 0, drift_ppm: 0, anchor_ms: 0}
  ]

  @type check :: :product_code | :serial | :energy_unit
  @type t :: %__MODULE__{
          unit_id: 1..247,
          profile: Profile.t(),
          values: %{String.t() => Decimal.t()},
          word_order: :high_first | :low_first | nil,
          identity: %{optional(check()) => String.t() | 0..0xFFFF | :absent},
          firmware: %{optional(Profile.firmware_name()) => String.t() | :absent},
          selectors: %{optional(0..0xFFFF) => 0..0xFFFF},
          settling: %{optional(0..0xFFFF) => {shown :: 0..0xFFFF, until_ms :: integer()}},
          stores: Stores.t() | nil,
          clock: %{offset_s: integer(), drift_ppm: integer(), anchor_ms: integer()}
        }

  @type write_code :: 6 | 16

  @names %{
    software: "SIM-SW",
    firmware_1: "SIM-F1",
    firmware_2: "SIM-F2",
    modbus_version: "0100"
  }

  # Selector PDU addresses (register number − 40001), source IDs elite_440-a
  # and elite_500-a, and how long each takes to show its entry, in ms.
  @selectors %{
    "elite_440" => %{
      function_code: 6,
      other: {16, 2},
      addresses: %{history: 520, snapshot: 700, load_survey_parameter: 800, load_survey_day: 801},
      settle_ms: %{}
    },
    "elite_500" => %{
      function_code: 16,
      other: {6, 1},
      addresses: %{
        history: 900,
        snapshot: 1500,
        load_survey_day: 5002,
        load_survey_parameter: 5003
      },
      settle_ms: %{load_survey_day: 100, load_survey_parameter: 100}
    }
  }

  # Identity blocks one request reads whole, by PDU address, seen on one meter
  # each (2026-11-14).
  @blocks %{"elite_440" => [0..35], "elite_500" => [1999..2026]}

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
      selectors: selectors(profile),
      stores: Stores.new(profile, Map.merge(zeros, values))
    }
  end

  defp selectors(%Profile{name: name}) do
    case @selectors do
      %{^name => %{addresses: addresses}} -> Map.new(addresses, fn {_, a} -> {a, 0} end)
      _ -> %{}
    end
  end

  @doc "Set the meter's clock: `offset_s` from the host's, gaining `drift_ppm`."
  @spec clock(t(), integer(), integer()) :: t()
  def clock(%__MODULE__{clock: clock} = meter, offset_s, drift_ppm)
      when is_integer(offset_s) and is_integer(drift_ppm),
      do: %{meter | clock: %{clock | offset_s: offset_s, drift_ppm: drift_ppm}}

  @doc "Anchor the meter at host time `host_ms`: its drift and its stores count from there."
  @spec anchor(t(), integer()) :: t()
  def anchor(%__MODULE__{clock: clock} = meter, host_ms),
    do: %{meter | clock: %{clock | anchor_ms: host_ms}}

  @doc "Change what the meter stores. See `Simulator.Stores.change/2`."
  @spec stores(t(), [Stores.option()]) :: t()
  def stores(meter, []), do: meter

  def stores(%__MODULE__{stores: %Stores{} = stores} = meter, opts),
    do: %{meter | stores: Stores.change(stores, opts)}

  # contract: test/simulator/meter_test.exs "time/2"
  @doc "The meter's clock at host time `host_ms`, to the second."
  @spec time(t(), integer()) :: NaiveDateTime.t()
  def time(%__MODULE__{clock: clock}, host_ms) do
    drift = div((host_ms - clock.anchor_ms) * clock.drift_ppm, 1_000_000)

    (host_ms + clock.offset_s * 1000 + drift)
    |> Integer.floor_div(1000)
    |> DateTime.from_unix!()
    |> DateTime.to_naive()
  end

  @doc """
  What the meter holds at host time `host_ms` for history or snapshot `n`,
  or load-survey `{day, parameter}`. See `Simulator.Stores`.
  """
  @spec stored(t(), :history | :snapshot | :load_survey, term(), integer()) ::
          {:ok, Stores.entry() | Stores.day()} | :none
  def stored(%__MODULE__{} = meter, :load_survey, {day, parameter}, host_ms),
    do:
      Stores.day(
        meter.stores,
        meter.profile,
        day,
        parameter,
        time(meter, host_ms),
        started(meter)
      )

  def stored(%__MODULE__{} = meter, store, n, host_ms) when store in [:history, :snapshot],
    do: Stores.entry(meter.stores, meter.profile, store, n, time(meter, host_ms), started(meter))

  defp started(%__MODULE__{clock: %{anchor_ms: anchor_ms}} = meter), do: time(meter, anchor_ms)

  # contract: test/simulator/meter_test.exs "write/5"
  @doc """
  Write one selector register at host time `host_ms`, as function code
  `function_code`. Anything but a selector write this model takes is the
  exception code a meter answers.
  """
  @spec write(t(), write_code(), 0..0xFFFF, 0..0xFFFF, integer()) ::
          {:ok, t()} | {:exception, 1..3}
  def write(%__MODULE__{profile: %Profile{name: name}} = meter, fc, address, value, host_ms) do
    case @selectors do
      %{^name => %{function_code: ^fc} = model} -> selector(meter, model, address, value, host_ms)
      %{^name => %{other: {^fc, code}}} -> {:exception, code}
      _ -> {:exception, 1}
    end
  end

  defp selector(meter, model, address, value, host_ms) do
    case Enum.find(model.addresses, fn {_, a} -> a == address end) do
      nil ->
        {:exception, 2}

      {name, _} ->
        if Stores.allows?(meter.stores, name, value),
          do: {:ok, settle(meter, address, value, host_ms, Map.get(model.settle_ms, name, 0))},
          else: {:exception, 3}
    end
  end

  defp settle(meter, address, value, host_ms, settle_ms) do
    shown = shown(meter, address, host_ms)

    %{
      meter
      | selectors: Map.put(meter.selectors, address, value),
        settling: Map.put(meter.settling, address, {shown, host_ms + settle_ms})
    }
  end

  # The entry a selector shows at `host_ms`: its value, or the one before it while it settles.
  defp shown(%__MODULE__{selectors: selectors, settling: settling}, address, host_ms) do
    case settling do
      %{^address => {shown, until_ms}} when host_ms < until_ms -> shown
      _ -> Map.fetch!(selectors, address)
    end
  end

  @doc "Set a selector this meter has, by PDU address, whatever any client asked, at once."
  @spec select(t(), 0..0xFFFF, 0..0xFFFF) :: t()
  def select(%__MODULE__{selectors: selectors, settling: settling} = meter, address, value)
      when is_map_key(selectors, address),
      do: %{
        meter
        | selectors: Map.put(selectors, address, value),
          settling: Map.delete(settling, address)
      }

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

  # contract: test/simulator/meter_test.exs "read/5"
  @doc """
  The words at `count` consecutive addresses at host time `host_ms`, or
  `:unmapped` if any address holds nothing.
  """
  @spec read(t(), Profile.table(), 0..0xFFFF, pos_integer(), integer()) ::
          {:ok, [0..0xFFFF]} | :unmapped
  def read(meter, table, address, count, host_ms) do
    bank = bank(meter, table, host_ms)
    words = Enum.map(address..(address + count - 1)//1, &Map.get(bank, &1))
    if Enum.any?(words, &is_nil/1), do: :unmapped, else: {:ok, words}
  end

  defp bank(
         %__MODULE__{profile: profile, values: values, word_order: override} = meter,
         table,
         host_ms
       ) do
    registers =
      for {key, %{table: ^table} = spec} <- profile.registers,
          {word, offset} <- Enum.with_index(Encode.words(order(spec, override), values[key])),
          into: %{},
          do: {spec.address + offset, word}

    meter
    |> block_bank(table)
    |> Map.merge(stores_bank(meter, table, host_ms))
    |> Map.merge(registers)
    |> Map.merge(identity_bank(meter, table))
    |> Map.merge(firmware_bank(meter, table))
    |> Map.merge(selector_bank(meter, table))
    |> Map.drop(absent(meter, table))
  end

  defp block_bank(%__MODULE__{profile: %Profile{name: name}}, :holding),
    do: for(block <- Map.get(@blocks, name, []), address <- block, into: %{}, do: {address, 0})

  defp block_bank(_meter, :input), do: %{}

  defp absent(%__MODULE__{profile: profile, identity: identity, firmware: names}, table) do
    specs =
      for({check, :absent} <- identity, do: profile.identity[check]) ++
        for {name, :absent} <- names, do: profile.firmware[name]

    for %{table: ^table, address: address} = spec <- specs,
        offset <- 0..(Map.get(spec, :count, 1) - 1),
        do: address + offset
  end

  defp stores_bank(
         %__MODULE__{stores: %Stores{} = stores, profile: profile} = meter,
         :holding,
         host_ms
       ) do
    %{addresses: addresses} = Map.fetch!(@selectors, profile.name)
    selections = Map.new(addresses, fn {name, a} -> {name, shown(meter, a, host_ms)} end)
    Stores.bank(stores, profile, selections, time(meter, host_ms), started(meter))
  end

  defp stores_bank(_meter, _table, _host_ms), do: %{}

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
