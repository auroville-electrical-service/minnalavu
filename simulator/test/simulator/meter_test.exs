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

    test "an Elite 440 answers its invented names; the registers between them stay unmapped" do
      meter = Meter.new(1, Profile.load!("elite_440"))
      assert {:ok, software} = Meter.read(meter, :holding, 4, 4)
      assert text(software) == "SIM-SW"
      assert {:ok, [0x0100]} = Meter.read(meter, :holding, 18, 1)
      assert :unmapped = Meter.read(meter, :holding, 0, 25)
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
end
