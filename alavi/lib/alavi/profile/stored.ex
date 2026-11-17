defmodule Alavi.Profile.Stored do
  @moduledoc """
  Where a meter keeps the entries a copy reads, parsed from a profile's
  `meter_clock` and `stored` sections: per store, the selector that chooses
  an entry (by its `Alavi.Modbus.Selector` name), the count of entries held,
  the entry's stamp, the support mask, and its registers (history, snapshot)
  or its interval, values and parameters (load survey). Every address is a
  holding register's PDU address. Pure data; the decode is
  `Alavi.Decode.Stored`.
  """

  alias Alavi.Config.Fields
  alias Alavi.Modbus.Selector
  alias Alavi.Profile.Register

  @enforce_keys [:history, :snapshot, :load_survey]
  defstruct @enforce_keys

  @type address :: 0..0xFFFF
  @type store :: :history | :snapshot | :load_survey
  @typedoc "An unsigned 32-bit count of seconds since `epoch`, the meter's local time."
  @type stamp :: %{
          address: address(),
          word_order: Register.word_order(),
          epoch: NaiveDateTime.t(),
          source: Register.source()
        }
  @type mask :: %{
          address: address(),
          type: :u16 | :u32 | :u64,
          word_order: Register.word_order(),
          source: Register.source()
        }
  @type register :: %{
          key: String.t(),
          address: address(),
          word_order: Register.word_order(),
          unit: String.t(),
          kind: Register.kind(),
          mask_bit: 0..63 | nil,
          source: Register.source()
        }
  @typedoc "`mask` is nil exactly when no register has a `mask_bit`."
  @type block :: %{
          selector: :history | :snapshot,
          available: address(),
          stamp: stamp(),
          mask: mask() | nil,
          registers: [register(), ...],
          sources: [Register.source()]
        }
  @type parameter :: %{
          number: 0..63,
          key: String.t(),
          unit: String.t(),
          kind: Register.kind(),
          source: Register.source()
        }
  @typedoc """
  A register that must read `value` for the survey the selectors show to be
  the one this section describes: which logger they show, or whether energy
  is kept per interval.
  """
  @type requirement :: %{key: String.t(), address: address(), value: 0..0xFFFF}
  @typedoc "`values` holds the day's f32 values, `per_request` intervals to a read."
  @type survey :: %{
          day: :load_survey_day,
          parameter: :load_survey_parameter,
          requires: [requirement()],
          available: address(),
          interval: address(),
          stamp: stamp(),
          mask: mask(),
          values: %{address: address(), word_order: Register.word_order(), per_request: 1..62},
          parameters: [parameter(), ...],
          sources: [Register.source()]
        }
  @type t :: %__MODULE__{history: block(), snapshot: block(), load_survey: survey()}

  @word_orders %{"high_first" => :high_first, "low_first" => :low_first}
  @masks %{"u16" => :u16, "u32" => :u32, "u64" => :u64}
  @kinds %{
    "cumulative" => :cumulative,
    "interval" => :interval,
    "demand" => :demand,
    "instantaneous" => :instantaneous
  }
  @units ~w(Wh kWh varh kvarh VAh kVAh V A Hz)
  @cited ~w(source verified_on_device)

  # contract: test/alavi/profile/stored_test.exs "parse/1"
  @spec parse(term()) :: {:ok, t()} | {:error, String.t()}
  def parse(%{} = json) do
    with :ok <- Fields.only(json, ~w(history snapshot load_survey)),
         {:ok, history} <- section(json, "history", &block(&1, :history)),
         {:ok, snapshot} <- section(json, "snapshot", &block(&1, :snapshot)),
         {:ok, survey} <- section(json, "load_survey", &survey/1) do
      {:ok, %__MODULE__{history: history, snapshot: snapshot, load_survey: survey}}
    end
  end

  def parse(_json), do: {:error, "stored must be an object"}

  # contract: test/alavi/profile/stored_test.exs "parse/1"
  @spec parse_clock(term()) :: {:ok, stamp()} | {:error, String.t()}
  def parse_clock(json) do
    with {:error, reason} <- stamp(json), do: {:error, "meter_clock: #{reason}"}
  end

  @spec sources(t()) :: [Register.source()]
  def sources(%__MODULE__{} = stored),
    do: stored.history.sources ++ stored.snapshot.sources ++ stored.load_survey.sources

  @doc "The store's section."
  @spec section(t(), :history | :snapshot) :: block()
  @spec section(t(), :load_survey) :: survey()
  def section(%__MODULE__{} = stored, store), do: Map.fetch!(stored, store)

  defp section(json, field, parse) do
    case Map.fetch(json, field) do
      {:ok, %{} = entry} -> prefixed(parse.(entry), "stored.#{field}")
      _ -> {:error, "stored.#{field} must be an object"}
    end
  end

  defp prefixed({:ok, _} = ok, _prefix), do: ok
  defp prefixed({:error, reason}, prefix), do: {:error, "#{prefix}: #{reason}"}

  defp block(json, store) do
    with :ok <- Fields.only(json, ~w(selector available stamp mask registers)),
         :ok <- selector(json, "selector", store),
         {:ok, available} <- field(json, "available", &count/1),
         {:ok, stamp} <- field(json, "stamp", &stamp/1),
         {:ok, mask} <- optional(json, "mask", &mask/1),
         {:ok, registers} <- Fields.each(json, "registers", &register(&1, store)),
         :ok <- unique(registers),
         :ok <- masked(mask, registers) do
      {:ok,
       %{
         selector: store,
         available: available.address,
         stamp: stamp,
         mask: mask,
         registers: registers,
         sources: [available.source, stamp.source | sources(mask, registers)]
       }}
    end
  end

  defp survey(json) do
    fields = ~w(selectors requires available interval stamp mask values parameters)

    with :ok <- Fields.only(json, fields),
         :ok <- selectors(json),
         {:ok, requires} <- requires(json),
         {:ok, available} <- field(json, "available", &count/1),
         {:ok, interval} <- field(json, "interval", &interval/1),
         {:ok, stamp} <- field(json, "stamp", &stamp/1),
         {:ok, mask} <- field(json, "mask", &mask/1),
         {:ok, values} <- field(json, "values", &values/1),
         {:ok, parameters} <- Fields.each(json, "parameters", &parameter/1),
         :ok <- unique(parameters) do
      {:ok,
       %{
         day: :load_survey_day,
         parameter: :load_survey_parameter,
         requires: Enum.map(requires, &Map.delete(&1, :source)),
         available: available.address,
         interval: interval.address,
         stamp: stamp,
         mask: mask,
         values: Map.delete(values, :source),
         parameters: parameters,
         sources:
           Enum.map(requires, & &1.source) ++
             [available.source, interval.source, stamp.source, mask.source, values.source] ++
             Enum.map(parameters, & &1.source)
       }}
    end
  end

  defp requires(json) do
    if Map.has_key?(json, "requires") do
      with {:ok, requires} <- Fields.each(json, "requires", &requirement/1),
           :ok <- Fields.unique(requires, & &1.key, "requires key"),
           do: {:ok, requires}
    else
      {:ok, []}
    end
  end

  defp requirement(json) do
    with :ok <- Fields.only(json, ~w(key table address type value) ++ @cited),
         {:ok, key} <- Fields.string(json, "key"),
         {:ok, address} <- holding(json, "u16"),
         {:ok, value} <- Fields.integer(json, "value", 0..0xFFFF),
         {:ok, source} <- cited(json),
         do: {:ok, %{key: key, address: address, value: value, source: source}}
  end

  defp sources(mask, registers),
    do: List.wrap(mask && mask.source) ++ Enum.map(registers, & &1.source)

  defp selector(json, field, name) do
    expected = Atom.to_string(name)

    case Map.fetch(json, field) do
      {:ok, ^expected} -> known(name)
      _ -> {:error, "#{field} must be #{inspect(expected)}"}
    end
  end

  defp selectors(json) do
    case Map.fetch(json, "selectors") do
      {:ok, %{"day" => "load_survey_day", "parameter" => "load_survey_parameter"} = s}
      when map_size(s) == 2 ->
        with :ok <- known(:load_survey_day), do: known(:load_survey_parameter)

      _ ->
        {:error,
         ~s(selectors must be {"day": "load_survey_day", "parameter": "load_survey_parameter"})}
    end
  end

  defp known(name) do
    if Enum.any?(Selector.allowlist(), &(&1.name == name)),
      do: :ok,
      else: {:error, "#{name} is not an allowlisted selector"}
  end

  defp field(json, name, parse) do
    case Map.fetch(json, name) do
      {:ok, %{} = entry} -> prefixed(parse.(entry), name)
      _ -> {:error, "#{name} must be an object"}
    end
  end

  defp optional(json, name, parse) do
    if Map.has_key?(json, name), do: field(json, name, parse), else: {:ok, nil}
  end

  defp count(json) do
    with :ok <- Fields.only(json, ~w(table address type) ++ @cited),
         {:ok, address} <- holding(json, "u16"),
         {:ok, source} <- cited(json),
         do: {:ok, %{address: address, source: source}}
  end

  defp interval(json) do
    with :ok <- Fields.only(json, ~w(table address type unit) ++ @cited),
         {:ok, address} <- holding(json, "u16"),
         :ok <- exactly(json, "unit", "min"),
         {:ok, source} <- cited(json),
         do: {:ok, %{address: address, source: source}}
  end

  defp stamp(%{} = json) do
    with :ok <- Fields.only(json, ~w(table address type word_order epoch) ++ @cited),
         {:ok, address} <- holding(json, "u32"),
         {:ok, order} <- Fields.lookup(json, "word_order", @word_orders),
         {:ok, epoch} <- epoch(json),
         {:ok, source} <- cited(json),
         do: {:ok, %{address: address, word_order: order, epoch: epoch, source: source}}
  end

  defp stamp(_json), do: {:error, "must be an object"}

  defp mask(json) do
    with :ok <- Fields.only(json, ~w(table address type word_order) ++ @cited),
         :ok <- exactly(json, "table", "holding"),
         {:ok, address} <- Fields.integer(json, "address", 0..0xFFFF),
         {:ok, type} <- Fields.lookup(json, "type", @masks),
         {:ok, order} <- mask_order(json, type),
         {:ok, source} <- cited(json),
         do: {:ok, %{address: address, type: type, word_order: order, source: source}}
  end

  # One word has no word order.
  defp mask_order(json, :u16) do
    if Map.has_key?(json, "word_order"),
      do: {:error, "a u16 mask has no word_order"},
      else: {:ok, :high_first}
  end

  defp mask_order(json, _type), do: Fields.lookup(json, "word_order", @word_orders)

  defp values(json) do
    with :ok <- Fields.only(json, ~w(table address type word_order per_request) ++ @cited),
         {:ok, address} <- holding(json, "f32"),
         {:ok, order} <- Fields.lookup(json, "word_order", @word_orders),
         {:ok, per_request} <- Fields.integer(json, "per_request", 1..62),
         {:ok, source} <- cited(json),
         do:
           {:ok, %{address: address, word_order: order, per_request: per_request, source: source}}
  end

  defp register(json, store) do
    fields = ~w(key table address type word_order unit kind mask_bit) ++ @cited

    with :ok <- Fields.only(json, fields),
         {:ok, key} <- Fields.string(json, "key"),
         {:ok, address} <- holding(json, "f32"),
         {:ok, order} <- Fields.lookup(json, "word_order", @word_orders),
         {:ok, unit, kind} <- quantity(json, store),
         {:ok, bit} <- mask_bit(json),
         {:ok, source} <- cited(json) do
      {:ok,
       %{
         key: key,
         address: address,
         word_order: order,
         unit: unit,
         kind: kind,
         mask_bit: bit,
         source: source
       }}
    end
  end

  defp parameter(json) do
    with :ok <- Fields.only(json, ~w(number key unit kind) ++ @cited),
         {:ok, number} <- Fields.integer(json, "number", 0..63),
         {:ok, key} <- Fields.string(json, "key"),
         {:ok, unit, kind} <- quantity(json, :load_survey),
         {:ok, source} <- cited(json),
         do: {:ok, %{number: number, key: key, unit: unit, kind: kind, source: source}}
  end

  # The kind rules the store's catalog also enforces: a load-survey quantity is
  # never cumulative, and no other store's is per interval.
  defp quantity(json, store) do
    with {:ok, unit} <- unit(json),
         {:ok, kind} <- Fields.lookup(json, "kind", @kinds) do
      case {store, kind} do
        {:load_survey, :cumulative} ->
          {:error, "a load-survey quantity cannot be cumulative"}

        {store, :interval} when store != :load_survey ->
          {:error, "only the load survey is per interval"}

        _ ->
          {:ok, unit, kind}
      end
    end
  end

  defp unit(json) do
    case Map.fetch(json, "unit") do
      {:ok, unit} when unit in @units -> {:ok, unit}
      _ -> {:error, "unit must be one of #{Enum.join(@units, ", ")}"}
    end
  end

  defp mask_bit(json) do
    if Map.has_key?(json, "mask_bit"),
      do: Fields.integer(json, "mask_bit", 0..63),
      else: {:ok, nil}
  end

  defp unique(entries) do
    with :ok <- Fields.unique(entries, & &1.key, "key") do
      bits = for %{mask_bit: bit} <- entries, bit != nil, do: bit
      numbers = for %{number: n} <- entries, do: n
      Fields.unique(bits ++ numbers, & &1, "mask bit or parameter number")
    end
  end

  defp masked(mask, registers) do
    if mask == nil == Enum.all?(registers, &(&1.mask_bit == nil)),
      do: :ok,
      else: {:error, "every register has a mask_bit exactly when there is a mask"}
  end

  defp holding(json, type) do
    with :ok <- exactly(json, "table", "holding"),
         :ok <- exactly(json, "type", type),
         do: Fields.integer(json, "address", 0..0xFFFF)
  end

  defp exactly(json, field, value) do
    if Map.get(json, field) == value,
      do: :ok,
      else: {:error, "#{field} must be #{inspect(value)}"}
  end

  defp epoch(json) do
    with {:ok, text} <- Fields.string(json, "epoch"),
         {:ok, %NaiveDateTime{microsecond: {0, 0}} = epoch} <- NaiveDateTime.from_iso8601(text) do
      {:ok, epoch}
    else
      _ -> {:error, "epoch must be a local date-time, YYYY-MM-DDTHH:MM:SS"}
    end
  end

  defp cited(json) do
    with {:ok, source} <- Register.parse_source(json["source"]),
         {:ok, _verified} <- Register.parse_verified(json),
         do: {:ok, source}
  end
end
