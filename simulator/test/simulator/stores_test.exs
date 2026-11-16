defmodule Simulator.StoresTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Simulator.{Meter, Profile}

  # Host times in ms. The meters are anchored at @start, and read at @now.
  @start 1_794_650_400_000
  @now @start
  @hour 3_600_000

  @fixture Path.expand("../../../contract/fixtures/stored-decode.v1.json", __DIR__)

  @selectors %{
    "elite_440" => %{
      code: 6,
      history: 520,
      snapshot: 700,
      load_survey_parameter: 800,
      load_survey_day: 801
    },
    "elite_500" => %{
      code: 16,
      history: 900,
      snapshot: 1500,
      load_survey_day: 5002,
      load_survey_parameter: 5003
    }
  }

  @live %{
    "active_energy_import" => Decimal.new("12000"),
    "active_energy_export" => Decimal.new("3000")
  }

  defp meter(name, values \\ @live, at \\ @start),
    do: 1 |> Meter.new(Profile.load!(name), values) |> Meter.anchor(at)

  defp select(meter, selector, value, at \\ @now) do
    %{code: code} = selectors = @selectors[meter.profile.name]
    {:ok, meter} = Meter.write(meter, code, selectors[selector], value, at)
    meter
  end

  defp words(meter, address, count, at \\ @now) do
    {:ok, words} = Meter.read(meter, :holding, address, count, at)
    words
  end

  # Decodes as contract/tools/stored_decode.py does.

  defp ordered(words, :high_first), do: words
  defp ordered(words, :low_first), do: Enum.reverse(words)

  defp integer(words, order),
    do: words |> ordered(order) |> Enum.reduce(0, &(&2 * 0x10000 + &1))

  defp stamp(%{address: address, word_order: order, epoch: epoch}, meter, at \\ @now),
    do: NaiveDateTime.add(epoch, meter |> words(address, 2, at) |> integer(order))

  defp f32(meter, address, order, at \\ @now) do
    case meter |> words(address, 2, at) |> ordered(order) do
      [0xFFFF, 0xFFFF] ->
        :not_finite

      [high, low] ->
        <<x::float-32>> = <<high::16, low::16>>
        x
    end
  end

  defp mask(%{address: address, type: type, word_order: order}, meter) do
    n = meter |> words(address, %{u16: 1, u32: 2, u64: 4}[type]) |> integer(order)
    for bit <- 0..63, (n >>> bit &&& 1) == 1, do: bit
  end

  # What a generated value is once a meter holds it in an f32.
  defp as_f32(:unsupported), do: :not_finite

  defp as_f32(value) do
    <<x::float-32>> = <<Decimal.to_float(value)::float-32>>
    x
  end

  defp ms(naive), do: naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:millisecond)

  defp fixture(section), do: @fixture |> File.read!() |> JSON.decode!() |> Map.fetch!(section)

  describe "entry/6" do
    for name <- ["elite_440", "elite_500"], store <- [:history, :snapshot] do
      test "#{name} #{store}: every entry held decodes to what the meter generated" do
        name = unquote(name)
        store = unquote(store)
        meter = meter(name) |> Meter.stores(snapshots: 3)
        block = meter.profile.stored[store]
        [count] = words(meter, block.available, 1)

        for n <- held(store, count) do
          meter = select(meter, store, n)
          {:ok, expected} = Meter.stored(meter, store, n, @now)
          assert stamp(block.stamp, meter) == expected.stamp

          for %{key: key, address: address, word_order: order} <- block.registers,
              do: assert(f32(meter, address, order) == as_f32(expected.values[key]), key)
        end
      end
    end

    test "histories are the 1st of each month back from this one; 0 is now" do
      meter = meter("elite_440")
      stamp = meter.profile.stored.history.stamp

      stamps =
        for n <- 0..6, do: meter |> select(:history, n) |> then(&stamp(stamp, &1))

      assert stamps == [
               ~N[2026-11-14 10:00:00],
               ~N[2026-11-01 00:00:00],
               ~N[2026-10-01 00:00:00],
               ~N[2026-09-01 00:00:00],
               ~N[2026-08-01 00:00:00],
               ~N[2026-07-01 00:00:00],
               ~N[2026-06-01 00:00:00]
             ]
    end

    test "snapshots are midnights back from today, as many as the 500 holds" do
      meter = meter("elite_500")
      %{available: available, stamp: stamp} = meter.profile.stored.snapshot
      assert words(meter, available, 1) == [52]
      assert stamp(stamp, select(meter, :snapshot, 0)) == ~N[2026-11-14 00:00:00]
      assert stamp(stamp, select(meter, :snapshot, 51)) == ~N[2026-09-24 00:00:00]
    end

    test "cumulative values rise from the live value at the anchor, at the quantity's rate" do
      meter = meter("elite_440")
      %{registers: [import_, export | _]} = meter.profile.stored.history
      on_1st = select(meter, :history, 1)

      # 322 hours before the anchor, at 0.25 kWh an hour for import, 0.5 for export.
      assert f32(on_1st, import_.address, :low_first) == 12_000 - 80.5
      assert f32(on_1st, export.address, :low_first) == 3000 - 161.0

      assert f32(select(meter, :history, 0), import_.address, :low_first, @now + 2 * @hour) ==
               12_000.5
    end

    test "a quantity the meter does not keep reads NaN, as fell to before it began, 0" do
      meter = meter("elite_440", %{"active_energy_import" => Decimal.new("1")})
      %{registers: registers} = meter.profile.stored.history
      by_key = Map.new(registers, &{&1.key, &1.address})
      on_1st = select(meter, :history, 1)

      assert f32(on_1st, by_key["reactive_energy_import"], :low_first) == :not_finite
      assert f32(on_1st, by_key["reactive_energy_export"], :low_first) == :not_finite
      assert f32(on_1st, by_key["active_energy_import"], :low_first) == 0.0
    end

    test "past the entries held, :none, and every register of the block reads 0xFFFF" do
      meter = meter("elite_500")
      %{stamp: stamp, registers: [first | _]} = meter.profile.stored.snapshot
      shown = Meter.select(meter, 1500, 60)
      assert Meter.stored(shown, :snapshot, 60, @now) == :none
      assert words(shown, stamp.address, 2) == [0xFFFF, 0xFFFF]
      assert f32(shown, first.address, :low_first) == :not_finite
    end
  end

  describe "day/7" do
    for name <- ["elite_440", "elite_500"] do
      test "#{name}: a past day's energies sum to the rise between the snapshots either side" do
        profile = Profile.load!(unquote(name))
        %{load_survey: survey, snapshot: snapshot} = profile.stored
        energies = for %{kind: :interval, number: n} <- survey.parameters, do: n

        meter =
          unquote(name)
          |> meter()
          |> Meter.stores(snapshots: 3, unsupported: [], parameters: energies)

        [minutes] = words(meter, survey.interval, 1)
        cumulative = Map.new(snapshot.registers, &{&1.key, &1})

        for %{kind: :interval, number: number, key: key} <- survey.parameters do
          meter = meter |> select(:load_survey_day, 1) |> select(:load_survey_parameter, number)
          read_at = @now + 100
          assert stamp(survey.stamp, meter, read_at) == ~N[2026-11-13 00:00:00]

          sum =
            for i <- 0..(div(1440, minutes) - 1), reduce: 0.0 do
              acc -> acc + f32(meter, survey.values.address + 2 * i, :low_first, read_at)
            end

          %{address: address} = cumulative[key]

          rise =
            f32(select(meter, :snapshot, 0), address, :low_first, read_at) -
              f32(select(meter, :snapshot, 1), address, :low_first, read_at)

          assert_in_delta sum, rise, 0.002, key
        end
      end
    end

    test "today's intervals not yet ended by the meter's clock read 0" do
      # 10:00 at 30-minute intervals: 20 have ended.
      meter = meter("elite_440") |> select(:load_survey_parameter, 0)
      values = meter.profile.stored.load_survey.values.address
      {:ok, %{values: generated}} = Meter.stored(meter, :load_survey, {0, 0}, @now)
      assert length(generated) == 48

      read = for i <- 0..47, do: f32(meter, values + 2 * i, :low_first)
      assert Enum.at(read, 19) == 0.125
      assert Enum.drop(read, 20) == List.duplicate(0.0, 28)
      assert read == Enum.map(generated, &as_f32/1)
    end

    test "averages are constants; a parameter the mask leaves out cannot be selected, and reads NaN" do
      meter = meter("elite_440")
      %{values: values, mask: mask} = meter.profile.stored.load_survey
      assert mask(mask, meter) == [0, 1, 8, 9, 19, 23, 27]

      assert f32(select(meter, :load_survey_parameter, 27), values.address, :low_first) == 50.0
      assert {:exception, 3} = Meter.write(meter, 6, 800, 10, @now)

      shown = Meter.select(meter, 800, 10)
      assert f32(shown, values.address, :low_first) == :not_finite
    end

    test "the interval register and the values follow the meter's interval" do
      meter = meter("elite_500") |> Meter.stores(interval: 30, days: 3)

      %{available: available, interval: interval, values: values} =
        meter.profile.stored.load_survey

      assert words(meter, available, 1) == [3]
      assert words(meter, interval, 1) == [30]
      assert {:ok, _} = Meter.read(meter, :holding, values.address, 96, @now)
      assert :unmapped = Meter.read(meter, :holding, values.address, 97, @now)
    end
  end

  describe "bank/5" do
    test "the meter clock and each store's stamp are the fixture's words for the same time" do
      for %{"profile" => name, "field" => field, "raw_words" => raw, "meter_time" => time} <-
            fixture("stamps"),
          meter_time = NaiveDateTime.from_iso8601!(time),
          {selector, n, now} <- reproducible(field, meter_time) do
        meter = meter(name, @live, ms(now))
        meter = if selector, do: select(meter, selector, n, ms(now)), else: meter

        address =
          case field do
            "meter_clock" -> meter.profile.meter_clock.address
            _ -> meter.profile.stored[store(field)].stamp.address
          end

        assert words(meter, address, 2, ms(now) + 100) == raw, "#{name} #{field} #{time}"
      end
    end

    test "the masks are the fixture's words for the same bits" do
      for %{"profile" => name, "field" => field, "raw_words" => raw} = case_ <- fixture("masks"),
          bits = Enum.map(case_["named"], & &1["bit"]) ++ case_["unnamed"],
          {store, opts} <- configurable(name, field, bits, case_["unnamed"]) do
        meter = name |> meter() |> Meter.stores(opts)
        %{address: address, type: type} = meter.profile.stored[store].mask
        assert words(meter, address, %{u16: 1, u32: 2, u64: 4}[type]) == raw, case_["why"]
      end
    end

    test "the unsupported quantities of a 500, which has no mask, read NaN" do
      meter = meter("elite_500") |> Meter.stores(unsupported: ["active_energy_import_l2"])
      %{registers: registers} = meter.profile.stored.history
      by_key = Map.new(registers, &{&1.key, &1.address})
      on_1st = select(meter, :history, 1)

      assert f32(on_1st, by_key["active_energy_import_l2"], :low_first) == :not_finite
      assert is_float(f32(on_1st, by_key["active_energy_import_l1"], :low_first))
    end
  end

  describe "change/2" do
    test "an interval that does not divide the day, or a parameter past 63, is refused" do
      stores = Meter.new(1, Profile.load!("elite_440")).stores
      assert_raise ArgumentError, fn -> Simulator.Stores.change(stores, interval: 7) end
      assert_raise ArgumentError, fn -> Simulator.Stores.change(stores, parameters: [64]) end
    end
  end

  defp held(:history, count), do: 0..count
  defp held(:snapshot, count), do: 0..(count - 1)

  # How to make a meter show `meter_time` in `field`, or nothing where the
  # simulator never stamps that time (a history minutes after midnight).
  defp reproducible("meter_clock", t), do: [{nil, nil, t}]

  defp reproducible("history.stamp", %NaiveDateTime{day: 1, hour: 0, minute: 0, second: 0} = t),
    do: [{:history, 1, NaiveDateTime.add(t, 13, :day)}]

  defp reproducible(field, %NaiveDateTime{hour: 0, minute: 0, second: 0} = t)
       when field in ["snapshot.stamp", "load_survey.stamp"],
       do: [{nil, nil, NaiveDateTime.add(t, 10, :hour)}]

  defp reproducible(_field, _t), do: []

  defp store("history.stamp"), do: :history
  defp store("snapshot.stamp"), do: :snapshot
  defp store("load_survey.stamp"), do: :load_survey

  # The stores options that give a mask those bits, where they can be given:
  # a block's mask has only the profile's bits.
  defp configurable(_name, "load_survey.mask", bits, _unnamed),
    do: [{:load_survey, [parameters: bits]}]

  defp configurable(name, field, bits, []) do
    store = if field == "history.mask", do: :history, else: :snapshot
    registers = Profile.load!(name).stored[store].registers
    [{store, [unsupported: for(r <- registers, r.mask_bit not in bits, do: r.key)]}]
  end

  defp configurable(_name, _field, _bits, _unnamed), do: []
end
