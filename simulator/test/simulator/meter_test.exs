defmodule Simulator.MeterTest do
  use ExUnit.Case, async: true

  alias Simulator.{Meter, Profile}

  # 2026-11-14 10:00:00 UTC, in ms.
  @at 1_794_650_400_000

  defp text(words), do: words |> Enum.map_join(&<<&1::16>>) |> String.trim_trailing(<<0>>)

  describe "read/5" do
    test "an Elite 500 answers its serial, NUL-padded, and its product code" do
      meter = Meter.new(7, Profile.load!("elite_500"))
      assert {:ok, serial} = Meter.read(meter, :holding, 1999, 8, @at)
      assert text(serial) == "SIM-7"
      assert {:ok, product} = Meter.read(meter, :holding, 2021, 6, @at)
      assert text(product) == "E500C-5102"
    end

    test "an Elite 440's serial can be overridden or unmapped" do
      meter = Meter.new(1, Profile.load!("elite_440"))

      assert {:ok, serial} =
               meter |> Meter.identify(:serial, "SIM00440") |> Meter.read(:holding, 0, 4, @at)

      assert text(serial) == "SIM00440"

      assert :unmapped =
               meter |> Meter.identify(:serial, :absent) |> Meter.read(:holding, 0, 4, @at)
    end

    test "an Elite 440 answers its invented names; the registers between them read 0" do
      meter = Meter.new(1, Profile.load!("elite_440"))
      assert {:ok, software} = Meter.read(meter, :holding, 4, 4, @at)
      assert text(software) == "SIM-SW"
      assert {:ok, [0x0100]} = Meter.read(meter, :holding, 18, 1, @at)
      assert {:ok, [0, 0]} = Meter.read(meter, :holding, 16, 2, @at)
    end

    test "an Elite 440 answers its identity block 0-35 in one request, and nothing past it" do
      meter = Meter.new(1, Profile.load!("elite_440"))
      assert {:ok, block} = Meter.read(meter, :holding, 0, 36, @at)
      assert text(Enum.slice(block, 0, 4)) == "SIM-1"
      assert text(Enum.slice(block, 19, 6)) == "ELITE440-445"
      assert Enum.at(block, 35) == 0x0100
      assert :unmapped = Meter.read(meter, :holding, 0, 37, @at)
    end

    test "an Elite 440 without the unit setting refuses the block, and answers the rest of it" do
      meter = Meter.new(1, Profile.load!("elite_440")) |> Meter.identify(:energy_unit, :absent)
      assert :unmapped = Meter.read(meter, :holding, 0, 36, @at)
      assert :unmapped = Meter.read(meter, :holding, 35, 1, @at)
      assert {:ok, [0]} = Meter.read(meter, :holding, 34, 1, @at)
      assert {:ok, _} = Meter.read(meter, :holding, 0, 35, @at)
    end

    test "an unmapped name is unmapped inside the block too" do
      meter = Meter.new(1, Profile.load!("elite_440")) |> Meter.name(:software, :absent)
      assert :unmapped = Meter.read(meter, :holding, 0, 36, @at)
      assert :unmapped = Meter.read(meter, :holding, 7, 1, @at)
      assert {:ok, [0]} = Meter.read(meter, :holding, 16, 1, @at)
    end

    test "an Elite 500 answers 1999-2026 in one request, but not from its unit register at 1957" do
      meter = Meter.new(3, Profile.load!("elite_500"))
      assert {:ok, block} = Meter.read(meter, :holding, 1999, 28, @at)
      assert text(Enum.slice(block, 0, 8)) == "SIM-3"
      assert text(Enum.slice(block, 22, 6)) == "E500C-5102"
      assert {:ok, [3]} = Meter.read(meter, :holding, 1957, 1, @at)
      assert :unmapped = Meter.read(meter, :holding, 1957, 70, @at)
    end

    test "an Elite 500's names, in its three-register module 2, can be overridden or unmapped" do
      meter = Meter.new(2, Profile.load!("elite_500"))
      assert {:ok, module_2} = Meter.read(meter, :holding, 2015, 3, @at)
      assert text(module_2) == "SIM-F2"

      renamed = meter |> Meter.name(:firmware_2, "SIM-F9") |> Meter.name(:modbus_version, "0B03")
      assert {:ok, module_2} = Meter.read(renamed, :holding, 2015, 3, @at)
      assert text(module_2) == "SIM-F9"
      assert {:ok, [0x0B03]} = Meter.read(renamed, :holding, 2020, 1, @at)

      assert :unmapped =
               meter |> Meter.name(:software, :absent) |> Meter.read(:holding, 2007, 4, @at)
    end
  end

  describe "write/5" do
    test "an Elite 440 takes 06 on its selectors, and the selector reads back" do
      meter = Meter.new(1, Profile.load!("elite_440"))
      assert {:ok, [0]} = Meter.read(meter, :holding, 520, 1, @at)

      for {address, value} <- [{520, 3}, {700, 0}, {800, 8}, {801, 3}] do
        assert {:ok, written} = Meter.write(meter, 6, address, value, @at)
        assert {:ok, [^value]} = Meter.read(written, :holding, address, 1, @at)
      end
    end

    test "an Elite 440 refuses 16 with exception 02, and any other address with 02" do
      meter = Meter.new(1, Profile.load!("elite_440"))
      assert {:exception, 2} = Meter.write(meter, 16, 520, 1, @at)
      assert {:exception, 2} = Meter.write(meter, 6, 519, 1, @at)
      assert {:exception, 2} = Meter.write(meter, 6, 199, 1, @at)
    end

    test "an Elite 500 takes 16 on its selectors, refuses 06 with 01, and other addresses with 02" do
      meter = Meter.new(3, Profile.load!("elite_500"))

      for {address, value} <- [{900, 5}, {1500, 9}, {5002, 5}, {5003, 9}] do
        assert {:ok, written} = Meter.write(meter, 16, address, value, @at)
        assert {:ok, [^value]} = Meter.read(written, :holding, address, 1, @at)
      end

      assert {:exception, 1} = Meter.write(meter, 6, 900, 1, @at)
      assert {:exception, 2} = Meter.write(meter, 16, 5001, 1, @at)
      assert {:exception, 2} = Meter.write(meter, 16, 5000, 1, @at)
    end
  end

  describe "write/5 on the stores" do
    test "a value past the entries the meter holds, or a parameter it lacks, is exception 03" do
      meter_440 = Meter.new(1, Profile.load!("elite_440"))
      meter_500 = Meter.new(3, Profile.load!("elite_500")) |> Meter.stores(days: 2)

      for {meter, fc, address, value} <- [
            {meter_440, 6, 520, 7},
            {meter_440, 6, 700, 1},
            {meter_440, 6, 800, 2},
            {meter_440, 6, 801, 7},
            {meter_500, 16, 900, 7},
            {meter_500, 16, 1500, 52},
            {meter_500, 16, 5002, 2},
            {meter_500, 16, 5003, 17}
          ] do
        assert {:exception, 3} = Meter.write(meter, fc, address, value, @at)
        assert {:ok, [0]} = Meter.read(meter, :holding, address, 1, @at)
      end
    end

    test "a 500's load survey shows the previous selection until 100 ms after the write" do
      meter = Meter.new(3, Profile.load!("elite_500")) |> Meter.anchor(@at)
      %{stamp: %{address: stamp}} = meter.profile.stored.load_survey
      {:ok, today} = Meter.read(meter, :holding, stamp, 2, @at)
      {:ok, written} = Meter.write(meter, 16, 5002, 1, @at)

      assert {:ok, [1]} = Meter.read(written, :holding, 5002, 1, @at)
      assert {:ok, ^today} = Meter.read(written, :holding, stamp, 2, @at + 99)
      assert {:ok, yesterday} = Meter.read(written, :holding, stamp, 2, @at + 100)
      assert yesterday != today

      # A write while settling keeps the entry still shown.
      {:ok, again} = Meter.write(written, 16, 5002, 2, @at + 50)
      assert {:ok, ^today} = Meter.read(again, :holding, stamp, 2, @at + 149)
    end

    test "a 440's load survey and a 500's histories show the new entry at once" do
      meter_440 = Meter.new(1, Profile.load!("elite_440")) |> Meter.anchor(@at)
      meter_500 = Meter.new(3, Profile.load!("elite_500")) |> Meter.anchor(@at)

      for {meter, fc, selector, stamp} <- [{meter_440, 6, 801, 803}, {meter_500, 16, 900, 901}] do
        {:ok, before} = Meter.read(meter, :holding, stamp, 2, @at)
        {:ok, written} = Meter.write(meter, fc, selector, 1, @at)
        assert {:ok, now} = Meter.read(written, :holding, stamp, 2, @at)
        assert now != before
      end
    end
  end

  describe "time/2" do
    test "the meter's clock runs from the host's by its offset, and drifts from its anchor" do
      meter = Meter.new(1, Profile.load!("elite_440")) |> Meter.anchor(@at)
      assert Meter.time(meter, @at) == ~N[2026-11-14 10:00:00]

      ahead = Meter.clock(meter, 1725, 0)
      assert Meter.time(ahead, @at) == ~N[2026-11-14 10:28:45]

      # 23 ppm is about 2 s a day: 23 s over the 1,000,000 s from the anchor.
      gaining = Meter.clock(meter, -99, 23)
      assert Meter.time(gaining, @at) == ~N[2026-11-14 09:58:21]
      assert Meter.time(gaining, @at + 1_000_000_000) == ~N[2026-11-25 23:45:24]
    end

    test "the clock register and the stamps follow the meter's clock, not the host's" do
      meter = Meter.new(3, Profile.load!("elite_500")) |> Meter.anchor(@at)
      behind = Meter.clock(meter, -11 * 3600, 0)
      # 2026-11-13 23:00:00 since 2000, high word first.
      seconds = NaiveDateTime.diff(~N[2026-11-13 23:00:00], ~N[2000-01-01 00:00:00])
      assert {:ok, [high, low]} = Meter.read(behind, :holding, 173, 2, @at)
      assert high * 0x10000 + low == seconds

      {:ok, %{stamp: stamp}} = Meter.stored(behind, :snapshot, 0, @at)
      assert stamp == ~N[2026-11-13 00:00:00]
    end
  end
end
