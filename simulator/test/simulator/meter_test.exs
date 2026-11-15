defmodule Simulator.MeterTest do
  use ExUnit.Case, async: true

  alias Simulator.{Meter, Profile}

  defp text(words), do: words |> Enum.map_join(&<<&1::16>>) |> String.trim_trailing(<<0>>)

  describe "read/4" do
    test "an Elite 500 answers its serial, NUL-padded, and its product code" do
      meter = Meter.new(7, Profile.load!("elite_500"))
      assert {:ok, serial} = Meter.read(meter, :holding, 1999, 8)
      assert text(serial) == "SIM-7"
      assert {:ok, product} = Meter.read(meter, :holding, 2021, 6)
      assert text(product) == "E500C-5102"
    end

    test "an Elite 440's serial can be overridden or unmapped" do
      meter = Meter.new(1, Profile.load!("elite_440"))

      assert {:ok, serial} =
               meter |> Meter.identify(:serial, "SIM00440") |> Meter.read(:holding, 0, 4)

      assert text(serial) == "SIM00440"
      assert :unmapped = meter |> Meter.identify(:serial, :absent) |> Meter.read(:holding, 0, 4)
    end

    test "an Elite 440 answers its invented names; the registers between them read 0" do
      meter = Meter.new(1, Profile.load!("elite_440"))
      assert {:ok, software} = Meter.read(meter, :holding, 4, 4)
      assert text(software) == "SIM-SW"
      assert {:ok, [0x0100]} = Meter.read(meter, :holding, 18, 1)
      assert {:ok, [0, 0]} = Meter.read(meter, :holding, 16, 2)
    end

    test "an Elite 440 answers its identity block 0-35 in one request, and nothing past it" do
      meter = Meter.new(1, Profile.load!("elite_440"))
      assert {:ok, block} = Meter.read(meter, :holding, 0, 36)
      assert text(Enum.slice(block, 0, 4)) == "SIM-1"
      assert text(Enum.slice(block, 19, 6)) == "ELITE440-445"
      assert Enum.at(block, 35) == 0x0100
      assert :unmapped = Meter.read(meter, :holding, 0, 37)
    end

    test "an Elite 440 without the unit setting refuses the block, and answers the rest of it" do
      meter = Meter.new(1, Profile.load!("elite_440")) |> Meter.identify(:energy_unit, :absent)
      assert :unmapped = Meter.read(meter, :holding, 0, 36)
      assert :unmapped = Meter.read(meter, :holding, 35, 1)
      assert {:ok, [0]} = Meter.read(meter, :holding, 34, 1)
      assert {:ok, _} = Meter.read(meter, :holding, 0, 35)
    end

    test "an unmapped name is unmapped inside the block too" do
      meter = Meter.new(1, Profile.load!("elite_440")) |> Meter.name(:software, :absent)
      assert :unmapped = Meter.read(meter, :holding, 0, 36)
      assert :unmapped = Meter.read(meter, :holding, 7, 1)
      assert {:ok, [0]} = Meter.read(meter, :holding, 16, 1)
    end

    test "an Elite 500 answers 1999-2026 in one request, but not from its unit register at 1957" do
      meter = Meter.new(3, Profile.load!("elite_500"))
      assert {:ok, block} = Meter.read(meter, :holding, 1999, 28)
      assert text(Enum.slice(block, 0, 8)) == "SIM-3"
      assert text(Enum.slice(block, 22, 6)) == "E500C-5102"
      assert {:ok, [3]} = Meter.read(meter, :holding, 1957, 1)
      assert :unmapped = Meter.read(meter, :holding, 1957, 70)
    end

    test "an Elite 500's names, in its three-register module 2, can be overridden or unmapped" do
      meter = Meter.new(2, Profile.load!("elite_500"))
      assert {:ok, module_2} = Meter.read(meter, :holding, 2015, 3)
      assert text(module_2) == "SIM-F2"

      renamed = meter |> Meter.name(:firmware_2, "SIM-F9") |> Meter.name(:modbus_version, "0B03")
      assert {:ok, module_2} = Meter.read(renamed, :holding, 2015, 3)
      assert text(module_2) == "SIM-F9"
      assert {:ok, [0x0B03]} = Meter.read(renamed, :holding, 2020, 1)
      assert :unmapped = meter |> Meter.name(:software, :absent) |> Meter.read(:holding, 2007, 4)
    end
  end

  describe "write/4" do
    test "an Elite 440 takes 06 on its selectors, and the selector reads back" do
      meter = Meter.new(1, Profile.load!("elite_440"))
      assert {:ok, [0]} = Meter.read(meter, :holding, 520, 1)

      for address <- [520, 700, 800, 801] do
        assert {:ok, written} = Meter.write(meter, 6, address, 3)
        assert {:ok, [3]} = Meter.read(written, :holding, address, 1)
      end
    end

    test "an Elite 440 refuses 16 with exception 02, and any other address with 02" do
      meter = Meter.new(1, Profile.load!("elite_440"))
      assert {:exception, 2} = Meter.write(meter, 16, 520, 1)
      assert {:exception, 2} = Meter.write(meter, 6, 519, 1)
      assert {:exception, 2} = Meter.write(meter, 6, 199, 1)
    end

    test "an Elite 500 takes 16 on its selectors, refuses 06 with 01, and other addresses with 02" do
      meter = Meter.new(3, Profile.load!("elite_500"))

      for address <- [900, 1500, 5002, 5003] do
        assert {:ok, written} = Meter.write(meter, 16, address, 9)
        assert {:ok, [9]} = Meter.read(written, :holding, address, 1)
      end

      assert {:exception, 1} = Meter.write(meter, 6, 900, 1)
      assert {:exception, 2} = Meter.write(meter, 16, 5001, 1)
      assert {:exception, 2} = Meter.write(meter, 16, 5000, 1)
    end
  end
end
