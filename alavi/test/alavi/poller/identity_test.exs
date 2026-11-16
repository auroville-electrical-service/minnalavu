defmodule Alavi.Poller.IdentityTest do
  use ExUnit.Case, async: true

  import Alavi.PollerCase
  import ExUnit.CaptureLog

  alias Alavi.{MissedRead, Reading}
  alias Simulator.Meter

  @import "active_energy_import"

  defp sim_meter(unit_id, profile, identity \\ %{}) do
    meter =
      Meter.new(unit_id, Simulator.Profile.load!(profile), %{@import => Decimal.new("5.000")})

    Enum.reduce(identity, meter, fn {check, value}, m -> Meter.identify(m, check, value) end)
  end

  defp poll!(sim_meters, meters, changes \\ %{}) do
    {sim, port} = start_chain!(:tcp, sim_meters)
    start_pollers!([endpoint(port, "tcp", meters, changes)])
    sim
  end

  test "a meter with another product code is missed in full, and the chain goes on" do
    log =
      capture_log(fn ->
        poll!(
          [sim_meter(1, "elite_440", product_code: "ELITE440-444"), sim_meter(2, "elite_440")],
          [meter(1, "elite_440"), meter(2, "elite_440")]
        )

        events = recorded!()
        assert length(events) == 2

        assert Enum.all?(
                 events,
                 &match?(%MissedRead{unit_id: 1, reason: {:profile_mismatch, _}, attempts: 0}, &1)
               )

        # The serial was read all the same, and labels the missed reads.
        assert Enum.all?(events, &match?(%MissedRead{meter_serial: "SIM-1"}, &1))

        assert [%MissedRead{reason: {:profile_mismatch, detail}} | _] = events
        assert detail =~ ~s("ELITE440-444")
        assert [%Reading{unit_id: 2} | _] = recorded!()
      end)

    assert log =~ "unit 1: profile mismatch: product code"
  end

  test "an energy unit setting other than the profile's is a mismatch" do
    capture_log(fn ->
      # 6: the Elite 500's exponent for mega.
      poll!([sim_meter(3, "elite_500", energy_unit: 6)], [meter(3, "elite_500")])

      assert [%MissedRead{reason: {:profile_mismatch, "energy unit code 6" <> _}} | _] =
               recorded!()
    end)
  end

  test "an Elite 440 with no unit register is read in its profile's unit" do
    poll!([sim_meter(1, "elite_440", energy_unit: :absent)], [meter(1, "elite_440")])
    assert [%Reading{unit_id: 1, profile: "elite_440", profile_version: 2} | _] = recorded!()
  end

  test "an Elite 500 with no unit register is missed with exception 02, under the serial read" do
    poll!([sim_meter(3, "elite_500", energy_unit: :absent)], [meter(3, "elite_500")])
    assert [%MissedRead{reason: {:exception, 2}, meter_serial: "SIM-3"} | _] = recorded!()
  end

  test "a mismatched meter is checked every round and read once it matches" do
    capture_log(fn ->
      sim =
        poll!(
          [sim_meter(1, "elite_440", product_code: "ELITE440-444")],
          [meter(1, "elite_440")],
          %{"interval_ms" => 10}
        )

      assert [%MissedRead{reason: {:profile_mismatch, _}} | _] = recorded!()
      Simulator.identify(sim, 1, :product_code, "ELITE440-445")
      await_unit!(1, &match?([%Reading{} | _], &1))
    end)
  end

  test "identity is read every round: a product code that stops matching is missed" do
    capture_log(fn ->
      sim = poll!([sim_meter(1, "elite_440")], [meter(1, "elite_440")], %{"interval_ms" => 10})

      assert [%Reading{product_code: "ELITE440-445"} | _] = recorded!()
      Simulator.identify(sim, 1, :product_code, "ELITE440-444")
      await_unit!(1, &match?([%MissedRead{reason: {:profile_mismatch, _}} | _], &1))
    end)
  end

  test "readings carry the serial read in their round, so a swapped meter's carry its own" do
    capture_log(fn ->
      sim = poll!([sim_meter(1, "elite_440")], [meter(1, "elite_440")], %{"interval_ms" => 10})

      assert [%Reading{meter_serial: "SIM-1"} | _] = recorded!()
      Simulator.identify(sim, 1, :serial, "SWAP-1")
      events = await_unit!(1, &match?([%Reading{meter_serial: "SWAP-1"} | _], &1))
      assert Enum.all?(events, &match?(%Reading{meter_serial: "SWAP-1"}, &1))
    end)
  end

  test "with no serial configured, readings carry the serial read" do
    poll!([sim_meter(3, "elite_500")], [Map.delete(meter(3, "elite_500"), "serial")])
    events = recorded!()
    assert length(events) == 4

    assert Enum.all?(
             events,
             &match?(%Reading{meter_serial: "SIM-3", product_code: "E500C-5102"}, &1)
           )
  end

  test "a serial other than the configured one is logged, and readings go under the one read" do
    log =
      capture_log(fn ->
        poll!([sim_meter(1, "elite_440")], [meter(1, "elite_440", %{"serial" => "CFG-1"})])
        events = recorded!()
        assert Enum.all?(events, &match?(%Reading{meter_serial: "SIM-1"}, &1))
      end)

    assert log =~ ~s(unit 1: serial "SIM-1" read, "CFG-1" configured)
  end

  test "a failed serial read misses the round, under no serial" do
    poll!([sim_meter(1, "elite_440", serial: :absent)], [meter(1, "elite_440")])
    events = recorded!()
    assert length(events) == 2

    assert Enum.all?(
             events,
             &match?(%MissedRead{reason: {:exception, 2}, meter_serial: nil}, &1)
           )
  end

  test "a serial with nothing printable in it misses the round, under no serial" do
    capture_log(fn ->
      poll!([sim_meter(1, "elite_440", serial: "")], [meter(1, "elite_440")])

      assert [%MissedRead{reason: {:profile_mismatch, "serial " <> _}, meter_serial: nil} | _] =
               recorded!()
    end)
  end
end
