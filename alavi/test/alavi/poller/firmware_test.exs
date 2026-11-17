defmodule Alavi.Poller.FirmwareTest do
  use ExUnit.Case, async: true

  import Alavi.PollerCase
  import ExUnit.CaptureLog

  alias Alavi.{FirmwareRead, MeterClockRead, MissedRead, Reading}
  alias Simulator.Meter

  @import "active_energy_import"
  @start ~U[2026-11-01 00:00:00Z]
  @day_s 86_400
  # The Elite 440's software name, as its profile places it.
  @software_440 4

  defp sim_meter(unit_id, profile, names \\ %{}) do
    meter =
      Meter.new(unit_id, Simulator.Profile.load!(profile), %{@import => Decimal.new("5.000")})

    Enum.reduce(names, meter, fn {name, value}, m -> Meter.name(m, name, value) end)
  end

  # The test process stands in for the status, so it sees each names read
  # (`Status.firmware/2`) and each round's end (`Status.round/2`). Options:
  # `sink`, `faults` set before the first round, `clock`, which replaces
  # the agent's, and `endpoint`, fields merged into the endpoint's config.
  # The agent's clock runs from `@start` at the monotonic clock's pace, so
  # that rounds come on their slots, and `advance/2` moves it on.
  defp poll!(sim_meters, meters, opts \\ []) do
    {sim, port} = start_chain!(:tcp, sim_meters)
    :ok = Simulator.faults(sim, Keyword.get(opts, :faults, []))
    {:ok, clock} = Agent.start_link(fn -> {@start, System.monotonic_time(:millisecond)} end)
    changes = Map.merge(%{"interval_ms" => 10}, Keyword.get(opts, :endpoint, %{}))

    opts = [
      config: config!([endpoint(port, "tcp", meters, changes)]),
      sink: {Keyword.get(opts, :sink, Alavi.TestSink), self()},
      clock: Keyword.get(opts, :clock, fn -> now(clock) end),
      raw_log: raw_log(),
      status: self(),
      selectors_dir: selectors_dir!()
    ]

    start_supervised!({Alavi.Pollers, opts})
    {sim, clock}
  end

  # The sink's and the status's messages for the next round, in the order sent.
  defp round! do
    receive do
      {:"$gen_cast", {:round, _events}} -> []
      {:"$gen_cast", {:raw_lines, _lines}} -> round!()
      {:"$gen_cast", {:firmware, read}} -> [{:names_read, read} | round!()]
      {:firmware, read} -> [{:sent, read} | round!()]
      {:recorded, events} -> [{:recorded, events} | round!()]
    after
      2_000 -> flunk("no round ended")
    end
  end

  defp names_read?(round), do: Enum.any?(round, &match?({:names_read, _}, &1))
  defp sent(round), do: for({:sent, read} <- round, do: read)

  defp now(clock) do
    {at, since} = Agent.get(clock, & &1)
    DateTime.add(at, System.monotonic_time(:millisecond) - since, :millisecond)
  end

  defp advance(clock, seconds),
    do: Agent.update(clock, fn {at, since} -> {DateTime.add(at, seconds), since} end)

  defp near_start?(at), do: DateTime.diff(at, @start, :millisecond) in 0..1_000

  defp until!(check, tries \\ 20) do
    round = round!()

    cond do
      check.(round) -> round
      tries > 1 -> until!(check, tries - 1)
      true -> flunk("no round matched")
    end
  end

  describe "start_link/1" do
    test "the first round reads the names after the readings, and sends them" do
      poll!([sim_meter(1, "elite_440")], [meter(1, "elite_440")])

      assert [{:recorded, readings}, {:names_read, read}, {:sent, read}] = round!()
      assert Enum.all?(readings, &match?(%Reading{}, &1))

      assert %FirmwareRead{
               unit_id: 1,
               meter_serial: "SIM-1",
               product_code: "ELITE440-445",
               software: "SIM-SW",
               firmware_1: "SIM-F1",
               firmware_2: "SIM-F2",
               modbus_version: "0100"
             } = read

      assert near_start?(read.timestamp)
    end

    test "the names are not read again within a day, then read, and sent only if changed" do
      {sim, clock} = poll!([sim_meter(1, "elite_440")], [meter(1, "elite_440")])
      assert names_read?(round!())

      # Read now, the changed name would be sent.
      :ok = Simulator.name(sim, 1, :software, "SIM-SW2")
      advance(clock, @day_s - 1)
      for _ <- 1..3, do: refute(names_read?(round!()))

      advance(clock, 1)
      round = until!(&names_read?/1)
      assert [%FirmwareRead{software: "SIM-SW2"}] = sent(round)

      advance(clock, @day_s)
      round = until!(&names_read?/1)
      assert sent(round) == []
    end

    test "the meter's clock is read with the names, once a day, under the serial the round read" do
      {_sim, clock} = poll!([sim_meter(1, "elite_440")], [meter(1, "elite_440")])

      assert names_read?(round!())

      assert_received {:meter_clock,
                       %MeterClockRead{
                         unit_id: 1,
                         meter_serial: "SIM-1",
                         profile: "elite_440",
                         profile_version: 2
                       } = read}

      assert near_start?(read.collector_at)
      assert abs(NaiveDateTime.diff(read.meter_time, NaiveDateTime.utc_now())) < 5

      for _ <- 1..3, do: refute(names_read?(round!()))
      refute_received {:meter_clock, _}

      advance(clock, @day_s)
      until!(&names_read?/1)
      assert_received {:meter_clock, %MeterClockRead{unit_id: 1}}
    end

    test "a new serial reads the names in its round, and sends them under it" do
      capture_log(fn ->
        {sim, _clock} = poll!([sim_meter(1, "elite_440")], [meter(1, "elite_440")])
        assert names_read?(round!())
        refute names_read?(round!())

        :ok = Simulator.identify(sim, 1, :serial, "SWAP-1")
        round = until!(&names_read?/1)
        assert [{:recorded, [%Reading{meter_serial: "SWAP-1"} | _]} | _] = round
        assert [%FirmwareRead{meter_serial: "SWAP-1", software: "SIM-SW"}] = sent(round)
      end)
    end

    test "a failed names read leaves the readings as they were, and is tried next round" do
      {sim, _clock} = poll!([sim_meter(1, "elite_440")], [meter(1, "elite_440")])
      assert [{:recorded, expected} | _] = round!()
      Simulator.faults(sim, silent_reads: [{1, @software_440}])

      log =
        capture_log(fn ->
          :ok = Simulator.identify(sim, 1, :serial, "SWAP-1")

          [{:recorded, readings}] =
            until!(&match?([{:recorded, [%{meter_serial: "SWAP-1"} | _]}], &1))

          assert Enum.all?(readings, &match?(%Reading{}, &1))
          refute Enum.any?(readings, &match?(%MissedRead{}, &1))

          assert Enum.map(readings, &{&1.register_key, &1.value}) ==
                   Enum.map(expected, &{&1.register_key, &1.value})

          assert [{:recorded, [%Reading{} | _]}] = round!()
          Simulator.clear_faults(sim)
          until!(&match?([{:recorded, _}, {:names_read, _}, {:sent, _}], &1))
        end)

      failed = "unit 1: firmware names not read, again next round: :timeout"
      assert length(String.split(log, failed)) >= 3
    end

    test "a name the meter refuses or leaves blank is sent as null" do
      log =
        capture_log(fn ->
          poll!(
            [sim_meter(3, "elite_500", firmware_2: :absent, software: "")],
            [meter(3, "elite_500")]
          )

          assert [{:recorded, _}, {:names_read, read}, {:sent, read}] = round!()

          assert %FirmwareRead{
                   software: nil,
                   firmware_1: "SIM-F1",
                   firmware_2: nil,
                   modbus_version: "0100"
                 } = read
        end)

      assert log =~ "firmware name software not given, sent as null: {:decode, :empty}"
      assert log =~ "firmware name firmware_2 not given, sent as null: {:exception, 2}"
    end

    for code <- [3, 4] do
      test "a name refused with exception #{code} fails the names read, tried next round" do
        log =
          capture_log(fn ->
            {sim, _clock} =
              poll!([sim_meter(1, "elite_440")], [meter(1, "elite_440")],
                faults: [refused_reads: [{{1, @software_440}, unquote(code)}]]
              )

            assert [{:recorded, _}] = round!()
            assert [{:recorded, _}] = round!()
            Simulator.clear_faults(sim)
            round = until!(&names_read?/1)
            assert [%FirmwareRead{software: "SIM-SW"}] = sent(round)
          end)

        assert log =~
                 "unit 1: firmware names not read, again next round: {:exception, #{unquote(code)}}"
      end
    end

    test "a failed names read costs no other meter on the endpoint its readings" do
      log =
        capture_log(fn ->
          {sim, _clock} =
            poll!(
              [sim_meter(1, "elite_440"), sim_meter(2, "elite_440")],
              [meter(1, "elite_440"), meter(2, "elite_440")],
              faults: [silent_reads: [{1, @software_440}]],
              clock: &DateTime.utc_now/0
            )

          assert [{:recorded, first}, {:recorded, second}, {:names_read, read}, {:sent, read}] =
                   round!()

          assert %FirmwareRead{unit_id: 2} = read
          assert Enum.all?(first ++ second, &match?(%Reading{}, &1))
          assert Enum.map(second, & &1.register_key) == Enum.map(first, & &1.register_key)
          assert Enum.all?(second, &(&1.unit_id == 2))

          # Read before the names: not after their timeouts, 100 ms each.
          gap = DateTime.diff(hd(second).timestamp, List.last(first).timestamp, :millisecond)
          assert gap < 100

          assert [{:recorded, _}, {:recorded, _}] = round!()
          Simulator.clear_faults(sim)
          round = until!(&names_read?/1)
          assert [%FirmwareRead{unit_id: 1}] = sent(round)
        end)

      assert log =~ "unit 1: firmware names not read, again next round: :timeout"
    end

    test "names the sink refused are read and sent again next round" do
      capture_log(fn ->
        poll!([sim_meter(1, "elite_440")], [meter(1, "elite_440")],
          sink: Alavi.RefusingSink,
          endpoint: %{"timeout_ms" => 1_000}
        )

        for _ <- 1..2, do: assert([{:recorded, _}, {:names_read, _}, {:sent, _}] = round!())
      end)
    end
  end
end
