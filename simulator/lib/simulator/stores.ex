defmodule Simulator.Stores do
  @moduledoc """
  What a simulated meter keeps behind its selectors: billing histories, daily
  snapshots and load-survey days, laid out as the profile's `stored` section
  says, and the meter clock at the profile's `meter_clock`. Nothing is kept:
  every entry is computed from the meter's clock when it is read.

  Each cumulative quantity rises in a straight line, `rates` per hour from
  `base` at the meter-clock time the meter was anchored (`Simulator.Meter`),
  and is never below 0, as from a meter installed new. A quantity the meter
  reads live starts from its live value at `Simulator.Meter.new/3`; later
  puts change what it reads live, not what it stored. Others start from an
  invented value. So histories and snapshots hold the cumulative value at
  their stamp, and a load-survey energy interval holds the rise across it:
  the intervals of a day sum to the difference of the snapshots either side.

  - History `n` (1 to `histories`) is stamped the 1st of the month at
    00:00:00, `n` − 1 months before the current one; history 0 shows the
    values now, stamped now.
  - Snapshot `n` (0 to `snapshots` − 1) and load-survey day `n` (0 to
    `days` − 1) are stamped midnight, `n` days before today.
  - A load-survey interval that has not ended by the meter's clock reads 0.
    A parameter's average (voltage, current, frequency) is a constant.
  - A quantity in `unsupported`, or a parameter not in `parameters`, reads
    NaN (0xFFFFFFFF); the masks show the rest.
  - Every register of an entry a selector shows but the meter does not
    hold (past the counts) reads 0xFFFF.
  - Each register the load survey `requires` reads its `settings` value,
    the required one unless changed; the survey reads the same either way.
  """

  alias Simulator.{Encode, Profile}

  @enforce_keys [
    :histories,
    :snapshots,
    :days,
    :interval,
    :settings,
    :unsupported,
    :parameters,
    :base,
    :rates
  ]
  defstruct @enforce_keys

  @typedoc """
  `interval` is the load survey's, in minutes; `settings` what each register
  the profile's load survey `requires` reads, by key, the required value
  unless changed; `parameters` the load-survey parameter numbers the meter
  supports; `rates` in the quantity's unit per hour.
  """
  @type t :: %__MODULE__{
          histories: 0..0xFFFF,
          snapshots: 0..0xFFFF,
          days: 0..0xFFFF,
          interval: pos_integer(),
          settings: %{String.t() => 0..0xFFFF},
          unsupported: MapSet.t(String.t()),
          parameters: MapSet.t(0..63),
          base: %{String.t() => Decimal.t()},
          rates: %{String.t() => Decimal.t()}
        }

  @type selector :: :history | :snapshot | :load_survey_day | :load_survey_parameter
  @type selections :: %{selector() => 0..0xFFFF}
  @type option ::
          {:histories, 0..0xFFFF}
          | {:snapshots, 0..0xFFFF}
          | {:days, 0..0xFFFF}
          | {:interval, pos_integer()}
          | {:settings, %{String.t() => 0..0xFFFF}}
          | {:unsupported, [String.t()]}
          | {:parameters, [0..63]}
          | {:base, %{String.t() => Decimal.t()}}
          | {:rates, %{String.t() => Decimal.t()}}
  @typedoc "A generated value, or `:unsupported` where the meter reads NaN."
  @type value :: Decimal.t() | :unsupported
  @type entry :: %{stamp: NaiveDateTime.t(), values: %{String.t() => value()}}
  @type day :: %{stamp: NaiveDateTime.t(), interval: pos_integer(), values: [value()]}

  # Per model, what the meters seen held: a 445's energies (history mask
  # 0x03F3) and load-survey parameters; a 500 with codes 0-16. Histories 6,
  # as on every meter seen; load-survey days fewer than any meter, for tests.
  @defaults %{
    "elite_440" => %{
      snapshots: 1,
      interval: 30,
      mask: 0x03F3,
      parameters: [0, 1, 8, 9, 19, 23, 27]
    },
    "elite_500" => %{snapshots: 52, interval: 15, mask: nil, parameters: Enum.to_list(0..16)}
  }

  @averages %{"V" => "240", "A" => "5", "Hz" => "50"}

  @doc "The stores of a new meter of `profile` whose live registers hold `values`."
  @spec new(Profile.t(), %{String.t() => Decimal.t()}) :: t() | nil
  def new(%Profile{stored: nil}, _values), do: nil

  def new(%Profile{name: name, stored: stored} = profile, values) do
    defaults = Map.fetch!(@defaults, name)
    keys = keys(stored)

    %__MODULE__{
      histories: 6,
      snapshots: defaults.snapshots,
      days: 7,
      interval: defaults.interval,
      settings: Map.new(stored.load_survey.requires, fn {key, r} -> {key, r.value} end),
      unsupported: unsupported(stored.history, defaults.mask),
      parameters: MapSet.new(defaults.parameters),
      base: keys |> Enum.with_index() |> Map.new(&base(&1, profile, values)),
      rates: keys |> Enum.with_index(1) |> Map.new(fn {k, i} -> {k, Decimal.div(i, 4)} end)
    }
  end

  defp keys(%{history: history, snapshot: snapshot, load_survey: survey}) do
    Enum.uniq(
      Enum.map(history.registers ++ snapshot.registers, & &1.key) ++
        for(%{kind: :interval, key: key} <- survey.parameters, do: key)
    )
  end

  defp base({key, _i}, %Profile{registers: registers}, values) when is_map_key(registers, key),
    do: {key, Map.fetch!(values, key)}

  defp base({key, i}, _profile, _values), do: {key, Decimal.new(1000 * (i + 1))}

  defp unsupported(_block, nil), do: MapSet.new()

  defp unsupported(%{registers: registers}, mask) do
    for %{key: key, mask_bit: bit} <- registers,
        Bitwise.band(mask, Bitwise.bsl(1, bit)) == 0,
        into: MapSet.new(),
        do: key
  end

  # contract: test/simulator/stores_test.exs "change/2"
  @doc "Change what the meter stores; options not given keep their value."
  @spec change(t(), [option()]) :: t()
  def change(%__MODULE__{} = stores, opts), do: Enum.reduce(opts, stores, &option/2)

  defp option({:interval, minutes}, stores)
       when is_integer(minutes) and minutes > 0 and rem(1440, minutes) == 0,
       do: %{stores | interval: minutes}

  defp option({:settings, settings}, stores) do
    if Enum.all?(settings, fn {key, value} ->
         Map.has_key?(stores.settings, key) and value in 0..0xFFFF
       end),
       do: %{stores | settings: Map.merge(stores.settings, settings)},
       else:
         raise(
           ArgumentError,
           "not a required register's key, or out of range: #{inspect(settings)}"
         )
  end

  defp option({:unsupported, keys}, stores), do: %{stores | unsupported: MapSet.new(keys)}
  defp option({:parameters, numbers}, stores), do: %{stores | parameters: parameters(numbers)}
  defp option({:base, base}, stores), do: %{stores | base: Map.merge(stores.base, base)}
  defp option({:rates, rates}, stores), do: %{stores | rates: Map.merge(stores.rates, rates)}

  defp option({count, n}, stores)
       when count in [:histories, :snapshots, :days] and n in 0..0xFFFF,
       do: Map.put(stores, count, n)

  defp option(option, _stores),
    do: raise(ArgumentError, "not a stores option, or out of range: #{inspect(option)}")

  defp parameters(numbers) do
    if Enum.all?(numbers, &(&1 in 0..63)),
      do: MapSet.new(numbers),
      else: raise(ArgumentError, "load-survey parameters are 0..63, got #{inspect(numbers)}")
  end

  @doc "Whether the meter takes `value` on `selector`: an entry it holds, or a parameter it supports."
  @spec allows?(t(), selector(), 0..0xFFFF) :: boolean()
  def allows?(%__MODULE__{histories: n}, :history, value), do: value <= n
  def allows?(%__MODULE__{snapshots: n}, :snapshot, value), do: value < n
  def allows?(%__MODULE__{days: n}, :load_survey_day, value), do: value < n
  def allows?(%__MODULE__{parameters: p}, :load_survey_parameter, value), do: value in p

  # contract: test/simulator/stores_test.exs "entry/6"
  @doc "History or snapshot `n` as the meter holds it at meter-clock time `now`, or `:none`."
  @spec entry(
          t(),
          Profile.t(),
          :history | :snapshot,
          0..0xFFFF,
          NaiveDateTime.t(),
          NaiveDateTime.t()
        ) ::
          {:ok, entry()} | :none
  def entry(stores, %Profile{stored: stored}, store, n, now, anchor) do
    case stamp(stores, store, n, now) do
      nil ->
        :none

      at ->
        values =
          Map.new(stored[store].registers, &{&1.key, cumulative(stores, &1.key, at, anchor)})

        {:ok, %{stamp: at, values: values}}
    end
  end

  defp stamp(%__MODULE__{}, :history, 0, now), do: now

  defp stamp(%__MODULE__{histories: h}, :history, n, now) when n <= h do
    now
    |> NaiveDateTime.to_date()
    |> Date.beginning_of_month()
    |> Date.shift(month: 1 - n)
    |> midnight()
  end

  defp stamp(%__MODULE__{snapshots: s}, :snapshot, n, now) when n < s, do: days_back(now, n)
  defp stamp(_stores, _store, _n, _now), do: nil

  defp days_back(now, n), do: now |> NaiveDateTime.to_date() |> Date.add(-n) |> midnight()
  defp midnight(date), do: NaiveDateTime.new!(date, ~T[00:00:00])

  defp cumulative(
         %__MODULE__{unsupported: unsupported, base: base, rates: rates},
         key,
         at,
         anchor
       ) do
    if MapSet.member?(unsupported, key),
      do: :unsupported,
      else: rise(base[key], rates[key], at, anchor)
  end

  defp rise(base, rate, at, anchor) do
    hours = Decimal.div(NaiveDateTime.diff(at, anchor), 3600)
    Decimal.max(Decimal.new(0), Decimal.add(base, Decimal.mult(rate, hours)))
  end

  # contract: test/simulator/stores_test.exs "day/7"
  @doc "Load-survey day `n`, parameter `parameter`, as the meter holds it at `now`, or `:none`."
  @spec day(t(), Profile.t(), 0..0xFFFF, 0..0xFFFF, NaiveDateTime.t(), NaiveDateTime.t()) ::
          {:ok, day()} | :none
  def day(%__MODULE__{days: days}, _profile, n, _parameter, _now, _anchor) when n >= days,
    do: :none

  def day(
        %__MODULE__{interval: minutes} = stores,
        %Profile{stored: stored},
        n,
        parameter,
        now,
        anchor
      ) do
    stamp = days_back(now, n)
    spec = Enum.find(stored.load_survey.parameters, &(&1.number == parameter))

    values =
      for i <- 0..(div(1440, minutes) - 1) do
        start = NaiveDateTime.add(stamp, i * minutes * 60)

        interval(
          stores,
          spec,
          parameter,
          {start, NaiveDateTime.add(start, minutes * 60)},
          now,
          anchor
        )
      end

    {:ok, %{stamp: stamp, interval: minutes, values: values}}
  end

  defp interval(stores, spec, parameter, {start, stop}, now, anchor) do
    cond do
      not MapSet.member?(stores.parameters, parameter) -> :unsupported
      NaiveDateTime.after?(stop, now) -> Decimal.new(0)
      true -> measured(stores, spec, start, stop, anchor)
    end
  end

  defp measured(_stores, nil, _start, _stop, _anchor), do: Decimal.new(0)

  defp measured(
         %__MODULE__{base: base, rates: rates},
         %{kind: :interval, key: key},
         start,
         stop,
         anchor
       ),
       do:
         Decimal.sub(
           rise(base[key], rates[key], stop, anchor),
           rise(base[key], rates[key], start, anchor)
         )

  defp measured(_stores, %{unit: unit}, _start, _stop, _anchor),
    do: Decimal.new(Map.get(@averages, unit, "0"))

  # contract: test/simulator/stores_test.exs "bank/5"
  @doc """
  The holding registers of the meter clock and every store, by PDU address,
  with `selections` the entries the selectors show.
  """
  @spec bank(t(), Profile.t(), selections(), NaiveDateTime.t(), NaiveDateTime.t()) ::
          %{(0..0xFFFF) => 0..0xFFFF}
  def bank(
        stores,
        %Profile{meter_clock: clock, stored: stored} = profile,
        selections,
        now,
        anchor
      ) do
    [
      stamp_bank(clock, now),
      block_bank(stores, profile, :history, selections.history, now, anchor),
      block_bank(stores, profile, :snapshot, selections.snapshot, now, anchor),
      survey_bank(stores, profile, selections, now, anchor),
      %{
        stored.history.available => stores.histories,
        stored.snapshot.available => stores.snapshots
      }
    ]
    |> Enum.reduce(&Map.merge(&2, &1))
  end

  defp block_bank(stores, %Profile{stored: stored} = profile, store, n, now, anchor) do
    %{stamp: stamp, mask: mask, registers: registers} = stored[store]

    words =
      case entry(stores, profile, store, n, now, anchor) do
        {:ok, %{stamp: at, values: values}} ->
          [stamp_bank(stamp, at) | Enum.map(registers, &f32_bank(&1, values[&1.key]))]

        :none ->
          [nan_bank(stamp.address, 2) | Enum.map(registers, &nan_bank(&1.address, 2))]
      end

    words
    |> Enum.reduce(&Map.merge(&2, &1))
    |> Map.merge(mask_bank(mask, block_bits(stores, registers)))
  end

  defp block_bits(stores, registers),
    do: for(%{key: k, mask_bit: b} <- registers, not MapSet.member?(stores.unsupported, k), do: b)

  defp survey_bank(
         stores,
         %Profile{stored: %{load_survey: survey}} = profile,
         selections,
         now,
         anchor
       ) do
    values =
      case day(
             stores,
             profile,
             selections.load_survey_day,
             selections.load_survey_parameter,
             now,
             anchor
           ) do
        {:ok, %{stamp: at, values: values}} ->
          Map.merge(stamp_bank(survey.stamp, at), series_bank(survey.values, values))

        :none ->
          Map.merge(
            nan_bank(survey.stamp.address, 2),
            nan_bank(survey.values.address, 2 * div(1440, stores.interval))
          )
      end

    values
    |> Map.merge(mask_bank(survey.mask, MapSet.to_list(stores.parameters)))
    |> Map.merge(%{survey.available => stores.days, survey.interval => stores.interval})
    |> Map.merge(Map.new(survey.requires, fn {key, r} -> {r.address, stores.settings[key]} end))
  end

  defp series_bank(%{address: address, word_order: order}, values) do
    values
    |> Enum.with_index()
    |> Enum.map(fn {v, i} -> f32_bank(%{address: address + 2 * i, word_order: order}, v) end)
    |> Enum.reduce(%{}, &Map.merge(&2, &1))
  end

  defp stamp_bank(%{address: address, word_order: order, epoch: epoch}, at),
    do:
      at_address(
        address,
        Encode.words(
          %{type: :u32, word_order: order, decimals: 0},
          Decimal.new(NaiveDateTime.diff(at, epoch))
        )
      )

  defp mask_bank(nil, _bits), do: %{}

  defp mask_bank(%{address: address, type: type, word_order: order}, bits) do
    mask = Enum.reduce(bits, 0, &Bitwise.bor(&2, Bitwise.bsl(1, &1)))

    at_address(
      address,
      Encode.words(%{type: type, word_order: order, decimals: 0}, Decimal.new(mask))
    )
  end

  defp f32_bank(%{address: address}, :unsupported), do: nan_bank(address, 2)

  defp f32_bank(%{address: address, word_order: order}, value),
    do: at_address(address, Encode.words(%{type: :f32, word_order: order, decimals: nil}, value))

  defp nan_bank(address, count), do: at_address(address, List.duplicate(0xFFFF, count))

  defp at_address(address, words),
    do: words |> Enum.with_index(address) |> Map.new(fn {w, a} -> {a, w} end)
end
