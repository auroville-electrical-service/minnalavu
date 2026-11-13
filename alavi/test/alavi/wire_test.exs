defmodule Alavi.WireTest do
  use ExUnit.Case, async: true

  alias Alavi.{MissedRead, Reading}

  doctest Alavi.Clock
  doctest Alavi.Wire

  @endpoint %{host: "10.0.0.21", port: 502}

  describe "Reading.to_wire/1" do
    test "the value is a decimal string, never a number" do
      reading = %Reading{
        endpoint: @endpoint,
        unit_id: 9,
        meter_serial: "SIM-9",
        profile: "elite_440",
        register_key: "active_energy_import",
        timestamp: ~U[2026-11-01 00:00:00Z],
        raw_words: [0x4700, 0],
        value: Decimal.new("1.234500E+3"),
        unit: "Wh"
      }

      assert %{"value" => "1234.500"} = Reading.to_wire(reading)
      assert %{"value" => "1000"} = Reading.to_wire(%{reading | value: Decimal.new("1E+3")})
    end
  end

  describe "MissedRead.to_wire/1" do
    defp missed(reason, raw_words \\ nil) do
      %MissedRead{
        endpoint: @endpoint,
        unit_id: 9,
        meter_serial: "SIM-9",
        profile: "elite_440",
        register_key: "active_energy_import",
        timestamp: ~U[2026-11-01 00:00:00Z],
        reason: reason,
        attempts: 3,
        raw_words: raw_words
      }
    end

    defp reason_of(reason) do
      missed(reason) |> MissedRead.to_wire() |> Map.take(["reason", "exception_code", "detail"])
    end

    test "a Modbus exception is named, with its code beside it" do
      assert reason_of({:exception, 0x0B}) ==
               %{"reason" => "exception", "exception_code" => 11, "detail" => nil}
    end

    test "a plain failure is named, with no code or detail" do
      assert reason_of(:timeout) == %{
               "reason" => "timeout",
               "exception_code" => nil,
               "detail" => nil
             }
    end

    test "a socket failure keeps its reason as the detail" do
      assert reason_of({:socket, :econnreset}) ==
               %{"reason" => "socket", "exception_code" => nil, "detail" => "econnreset"}

      assert reason_of({:unreachable, {:socket, :econnrefused}}) ==
               %{"reason" => "unreachable", "exception_code" => nil, "detail" => "econnrefused"}
    end

    test "a decode failure keeps its raw words" do
      wire = missed({:decode, :not_finite}, [0x7FC0, 0]) |> MissedRead.to_wire()
      assert %{"reason" => "decode", "detail" => "not_finite", "raw_words" => [0x7FC0, 0]} = wire
    end

    test "a detail is cut to the schema's 200 characters" do
      long = String.duplicate("x", 300)

      assert %{"detail" => detail} = reason_of({:profile_mismatch, long})
      assert String.length(detail) == 200

      assert %{"detail" => detail} = reason_of({:socket, {:tls_alert, long}})
      assert String.length(detail) == 200
    end
  end
end
