defmodule Alavi.WireTest do
  use ExUnit.Case, async: true

  alias Alavi.Buffer.Batch
  alias Alavi.{Clock, FirmwareRead, MissedRead, Reading, Wire}

  doctest Alavi.Clock
  doctest Alavi.Wire

  @endpoint %{host: "10.0.0.21", port: 502}
  @contract Path.expand("../../../contract", __DIR__)

  defp names do
    %FirmwareRead{
      endpoint: @endpoint,
      unit_id: 9,
      meter_serial: "SIM-9",
      product_code: "ELITE440-445",
      timestamp: ~U[2026-11-01 00:00:00Z],
      software: "SIM-SW",
      firmware_1: nil,
      firmware_2: "SIM-F2",
      modbus_version: "0B03"
    }
  end

  defp reading do
    %Reading{
      endpoint: @endpoint,
      unit_id: 9,
      meter_serial: "SIM-9",
      product_code: "ELITE440-445",
      profile: "elite_440",
      register_key: "active_energy_import",
      timestamp: ~U[2026-11-01 00:00:00Z],
      raw_words: [0x4700, 0],
      value: Decimal.new("1234.500"),
      unit: "Wh"
    }
  end

  defp backlog do
    %{
      events: 2,
      bytes: 100,
      batches: 1,
      oldest: ~U[2026-11-01 00:00:00Z],
      max_bytes: 1_000,
      refused: 0,
      discarded_files: 0,
      quarantined: 0
    }
  end

  defp wire(events) do
    batch = %Batch{
      id: "0b6f8d2e-5c1a-4e7b-9a3d-2f4c6e8a0b1c",
      clock: Clock.unsynced(),
      events: events
    }

    Wire.batch(batch, ~U[2026-11-01 00:05:00Z], backlog())
  end

  defp valid?(wire) do
    schema =
      @contract |> Path.join("schema/batch.v1.schema.json") |> File.read!() |> JSON.decode!()

    match?({:ok, _}, JSV.validate(wire, JSV.build!(schema, formats: true)))
  end

  describe "batch/3" do
    test "firmware reads go in firmware_reads, in the schema's shape, beside the readings" do
      wire = wire([reading(), names()])
      assert valid?(wire)
      assert [%{"value" => "1234.500"}] = wire["readings"]
      assert wire["missed_reads"] == []

      assert [%{"software" => "SIM-SW", "firmware_1" => nil, "meter_serial" => "SIM-9"}] =
               wire["firmware_reads"]
    end

    test "a batch with no firmware reads has no firmware_reads" do
      wire = wire([reading()])
      assert valid?(wire)
      refute Map.has_key?(wire, "firmware_reads")
    end

    test "a heartbeat, a batch with no events, still carries the clock and backlog" do
      wire = wire([])
      assert valid?(wire)

      assert %{"readings" => [], "missed_reads" => [], "clock" => %{"source" => "unsynced"}} =
               wire

      assert wire["backlog"]["events"] == 2
    end

    test "readings and missed reads of a request carry its id, valid in the schema" do
      id = "7d2c1f0e-4b3a-4c5d-8e6f-1a2b3c4d5e6f"
      wire = wire([%{reading() | request_id: id}, %{missed(:timeout) | request_id: id}, names()])
      assert valid?(wire)
      assert [%{"request_id" => ^id}] = wire["readings"]
      assert [%{"request_id" => ^id}] = wire["missed_reads"]
      refute Map.has_key?(hd(wire["firmware_reads"]), "request_id")
    end
  end

  describe "FirmwareRead.to_wire/1" do
    test "a name the meter did not give is null, and the timestamp ISO 8601" do
      assert %{
               "endpoint" => %{"host" => "10.0.0.21", "port" => 502},
               "unit_id" => 9,
               "product_code" => "ELITE440-445",
               "timestamp" => "2026-11-01T00:00:00Z",
               "firmware_1" => nil,
               "modbus_version" => "0B03"
             } = FirmwareRead.to_wire(names())
    end
  end

  describe "Reading.to_wire/1" do
    test "the value is a decimal string, never a number" do
      reading = %Reading{
        endpoint: @endpoint,
        unit_id: 9,
        meter_serial: "SIM-9",
        product_code: "ELITE440-445",
        profile: "elite_440",
        register_key: "active_energy_import",
        timestamp: ~U[2026-11-01 00:00:00Z],
        raw_words: [0x4700, 0],
        value: Decimal.new("1.234500E+3"),
        unit: "Wh"
      }

      assert %{"value" => "1234.500"} = Reading.to_wire(reading)
      assert %{"value" => "1000"} = Reading.to_wire(%{reading | value: Decimal.new("1E+3")})

      assert %{"meter_serial" => "SIM-9", "product_code" => "ELITE440-445"} =
               Reading.to_wire(reading)
    end

    test "a request id only when there is one: the schema refuses null" do
      refute Map.has_key?(Reading.to_wire(reading()), "request_id")

      assert %{"request_id" => "7d2c1f0e-4b3a-4c5d-8e6f-1a2b3c4d5e6f"} =
               Reading.to_wire(%{reading() | request_id: "7d2c1f0e-4b3a-4c5d-8e6f-1a2b3c4d5e6f"})
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

    test "a request id only when there is one" do
      refute Map.has_key?(MissedRead.to_wire(missed(:timeout)), "request_id")
      id = "7d2c1f0e-4b3a-4c5d-8e6f-1a2b3c4d5e6f"
      assert %{"request_id" => ^id} = MissedRead.to_wire(%{missed(:timeout) | request_id: id})
    end

    test "a missed read with no serial read carries null, and never a product code" do
      wire = %{missed(:timeout) | meter_serial: nil} |> MissedRead.to_wire()
      assert %{"meter_serial" => nil} = wire
      refute Map.has_key?(wire, "product_code")
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
