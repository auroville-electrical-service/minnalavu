defmodule Alavi.PollerTest do
  use ExUnit.Case, async: true

  import Alavi.PollerCase
  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Alavi.{LatencyDay, MissedRead, Reading}
  alias Alavi.Poller.Latency

  @moduletag :capture_log
  @active ["active_energy_import", "active_energy_export"]
  @keys %{
    "elite_440" => @active,
    "elite_500" => @active ++ ["reactive_energy_import", "reactive_energy_export"]
  }
  @contract Path.expand("../../../contract", __DIR__)

  describe "start_link/1" do
    for {framing, mode} <- [{"tcp", :tcp}, {"rtu_over_tcp", :rtu_over_tcp}] do
      test "#{framing}: reads every register of every meter on the chain, in order, as Decimal" do
        {_sim, port} = start_sim!(unquote(mode))
        meters = [meter(1, "elite_440"), meter(2, "elite_440"), meter(3, "elite_500")]
        clock = fn -> ~U[2026-11-01 00:00:00Z] end
        start_pollers!([endpoint(port, unquote(framing), meters)], clock)

        rounds = for _ <- 1..3, do: recorded!()

        assert Enum.map(rounds, &hd(&1).unit_id) == [1, 2, 3]

        for events <- rounds do
          assert Enum.map(events, & &1.register_key) == @keys[hd(events).profile]
          assert Enum.all?(events, &match?(%Reading{timestamp: ~U[2026-11-01 00:00:00Z]}, &1))
        end

        [import_ | _] = hd(rounds)
        assert import_.value == Decimal.new("123456")
        assert %{meter_serial: "SIM-1", product_code: "ELITE440-445"} = import_
        assert %{profile: "elite_440", profile_version: 2} = import_
        assert %{meter_serial: "SIM-3", product_code: "E500C-5102"} = hd(List.last(rounds))
        assert import_.endpoint == %{host: "127.0.0.1", port: port}
      end

      test "#{framing}: a silent meter is missed after its retries and the rest of the chain is read" do
        {sim, port} = start_sim!(unquote(mode))
        Simulator.faults(sim, silent_units: [2])
        meters = [meter(1, "elite_440"), meter(2, "elite_440"), meter(3, "elite_500")]
        start_pollers!([endpoint(port, unquote(framing), meters, %{"timeout_ms" => 50})])

        assert [%Reading{unit_id: 1} | _] = recorded!()
        assert [first | rest] = recorded!()
        # RTU over TCP closes on every timeout; a quick reconnect may be refused
        # while the endpoint still holds the old connection.
        assert %MissedRead{unit_id: 2, attempts: 3, reason: reason} = first
        assert reason in [:timeout, :closed]
        assert Enum.all?(rest, &match?(%MissedRead{attempts: 0, reason: ^reason}, &1))
        assert [%Reading{unit_id: 3} | _] = recorded!()
      end
    end

    test "a reading leaves in the shape of the batch schema" do
      {_sim, port} = start_sim!(:tcp)
      start_pollers!([endpoint(port, "tcp", [meter(3, "elite_500")])])
      readings = Enum.map(recorded!(), &Reading.to_wire/1)

      schema =
        @contract |> Path.join("schema/batch.v1.schema.json") |> File.read!() |> JSON.decode!()

      batch =
        @contract
        |> Path.join("fixtures/batch.v1.basic.json")
        |> File.read!()
        |> JSON.decode!()
        |> Map.put("readings", readings)

      assert {:ok, _} = JSV.validate(batch, JSV.build!(schema, formats: true))
      assert hd(readings)["value"] == "1234.5"
    end

    test "exception 0B is a missed read with no retry, and the next meter is read" do
      {_sim, port} = start_sim!(:tcp, missing_units: :gateway_error)
      start_pollers!([endpoint(port, "tcp", [meter(9, "elite_440"), meter(1, "elite_440")])])

      assert [first | rest] = recorded!()
      assert %MissedRead{unit_id: 9, reason: {:exception, 0x0B}, attempts: 1} = first
      assert Enum.all?(rest, &match?(%MissedRead{reason: {:exception, 0x0B}, attempts: 0}, &1))
      assert [%Reading{unit_id: 1} | _] = recorded!()
    end

    test "a gateway's two-byte reply under a byte of its own is rejected as unexpected and logged, " <>
           "retried on the same connection, and the rest of the chain is read" do
      {sim, port} = start_sim!(:tcp)
      Simulator.faults(sim, two_byte_replies: [{2, 7}])
      meters = [meter(1, "elite_440"), meter(2, "elite_440"), meter(3, "elite_500")]

      {rounds, log} =
        with_log(fn ->
          start_pollers!([endpoint(port, "tcp", meters)])
          for _ <- 1..3, do: recorded!()
        end)

      assert [[%Reading{unit_id: 1} | _], [first | rest], [%Reading{unit_id: 3} | _]] = rounds
      assert %MissedRead{unit_id: 2, attempts: 3, reason: :unexpected_response} = first
      assert Enum.all?(rest, &match?(%MissedRead{attempts: 0, reason: :unexpected_response}, &1))

      lines = log |> String.split("\n") |> Enum.filter(&(&1 =~ "127.0.0.1:#{port} unit 2:"))
      prefix = "unit 2: reply rejected (:unexpected_response), 8 bytes:"
      assert [_, _, _] = lines

      tids =
        for line <- lines do
          assert [_, tid] =
                   Regex.run(
                     ~r/#{Regex.escape(prefix)} ([0-9A-F]{2} [0-9A-F]{2}) 00 00 00 02 07 0B$/,
                     line
                   )

          tid
        end

      # One connection throughout: each retry carries the next transaction id, not 0 again.
      assert tids == Enum.uniq(tids)
      refute "00 00" in tl(tids)
    end

    test "exception 06 backs off before each retry, then the meter is missed until it clears" do
      {sim, port} = start_sim!(:tcp)
      Simulator.faults(sim, busy: true)
      started = System.monotonic_time(:millisecond)

      start_pollers!([
        endpoint(port, "tcp", [meter(1, "elite_440")], %{
          "busy_backoff_ms" => 60,
          "interval_ms" => 10
        })
      ])

      assert [%MissedRead{reason: {:exception, 6}, attempts: 3} | _] = recorded!()
      assert System.monotonic_time(:millisecond) - started >= 120

      Simulator.clear_faults(sim)
      await_unit!(1, &match?([%Reading{} | _], &1))
    end

    test "an unreachable endpoint is missed, and polling resumes once it is back" do
      {sim, port} = start_sim!(:tcp)
      :ok = Simulator.offline(sim)
      meters = [meter(1, "elite_440")]
      start_pollers!([endpoint(port, "tcp", meters, %{"interval_ms" => 10})])

      assert [first | rest] = recorded!()
      assert %MissedRead{reason: {:unreachable, {:socket, :timeout}}, attempts: 1} = first
      assert Enum.all?(rest, &match?(%MissedRead{attempts: 0}, &1))

      :ok = Simulator.online(sim)
      await_unit!(1, &match?([%Reading{} | _], &1))

      :ok = GenServer.stop(sim)
      await_unit!(1, &match?([%MissedRead{} | _], &1))
    end

    test "a meter's own interval overrides its endpoint's" do
      {_sim, port} = start_sim!(:tcp)

      start_pollers!([
        endpoint(
          port,
          "tcp",
          [meter(1, "elite_440"), meter(2, "elite_440", %{"interval_ms" => 86_400_000})],
          %{
            "interval_ms" => 20
          }
        )
      ])

      units = for _ <- 1..6, do: hd(recorded!()).unit_id
      assert Enum.count(units, &(&1 == 2)) == 1
      assert Enum.count(units, &(&1 == 1)) == 5
    end

    test "a sink that refuses events does not stop the poller" do
      {_sim, port} = start_sim!(:tcp)
      endpoints = [endpoint(port, "tcp", [meter(1, "elite_440")], %{"interval_ms" => 5})]

      opts = [
        config: config!(endpoints),
        sink: {Alavi.RefusingSink, self()},
        clock: &DateTime.utc_now/0,
        raw_log: raw_log(),
        status: no_status(),
        selectors_dir: selectors_dir!()
      ]

      sup = start_supervised!({Alavi.Pollers, opts})
      [{_, pid, _, _}] = Supervisor.which_children(sup)

      for _ <- 1..3, do: assert([%Reading{} | _] = recorded!())
      assert [{_, ^pid, _, _}] = Supervisor.which_children(sup)
    end

    test "a connect timer's message left behind does not stop the poller" do
      {_sim, port} = start_sim!(:tcp)

      sup =
        start_pollers!([endpoint(port, "tcp", [meter(1, "elite_440")], %{"interval_ms" => 5})])

      [{_, pid, _, _}] = Supervisor.which_children(sup)
      assert [%Reading{} | _] = recorded!()

      send(pid, {:timeout, make_ref(), :inet})
      for _ <- 1..3, do: assert([%Reading{} | _] = recorded!())
      assert [{_, ^pid, _, _}] = Supervisor.which_children(sup)
    end
  end

  describe "start_link/1, latency" do
    @describetag :tmp_dir

    # Pollers feeding a status that knows their endpoints.
    defp start_with_status!(endpoints, clock, dir) do
      config = config!(endpoints)
      status = :"status_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Alavi.Status,
         config: config,
         settings: [],
         version: "0.1.0",
         buffer: :no_such_buffer,
         file: Path.join(dir, "status.json"),
         clock: &DateTime.utc_now/0,
         tick_ms: 60_000,
         name: status},
        id: status
      )

      start_supervised!(
        {Alavi.Pollers,
         config: config,
         sink: {Alavi.TestSink, self()},
         clock: clock,
         raw_log: raw_log(),
         status: status,
         selectors_dir: selectors_dir!()}
      )

      status
    end

    defp latency(status, unit) do
      status
      |> Alavi.Status.read()
      |> Map.fetch!(:endpoints)
      |> hd()
      |> Map.fetch!(:meters)
      |> Enum.find(&(&1.unit_id == unit))
      |> Map.fetch!(:latency)
    end

    test "each answered request is timed per meter; a timeout is counted, not timed", ctx do
      {sim, port} = start_sim!(:tcp)
      Simulator.faults(sim, silent_units: [2], delay_ms: 20)
      meters = [meter(1, "elite_440"), meter(2, "elite_440"), meter(3, "elite_500")]
      endpoints = [endpoint(port, "tcp", meters, %{"timeout_ms" => 100})]
      status = start_with_status!(endpoints, &DateTime.utc_now/0, ctx.tmp_dir)

      assert [%Reading{unit_id: 3} | _] = await_unit!(3, &match?([%Reading{} | _], &1))
      :ok = eventually!(fn -> latency(status, 3) != nil end)

      today = Date.to_iso8601(Date.utc_today())
      # Its identity in two requests, 2 registers, 4 firmware names and its clock,
      # each reply 20 ms late.
      assert %{since: ^today, answered: 9, retries: 0, timeouts: 0} = l1 = latency(status, 1)
      assert l1.p50 >= 20 and l1.p50 <= l1.p99 and l1.p99 <= l1.max and l1.max < 100
      assert %{answered: 0, timeouts: 3, p50: nil, max: nil} = latency(status, 2)
      # Its identity in two requests, 4 registers, 4 names and its clock.
      assert %{answered: 11, timeouts: 0} = latency(status, 3)
    end

    test "an Elite 440 without the unit setting is read where a gateway answers a merged read of it with 0B",
         ctx do
      # As a real gateway answered holding 0-35 from three such meters, 2026-11-17.
      faults = [refused_spans: [{{1, 0, 36}, 11}]]
      status = start_440!(faults, ctx)

      assert [%Reading{unit_id: 1} | _] = recorded!()
      :ok = eventually!(fn -> latency(status, 1) != nil end)
      # Its identity in two requests, the unit setting refused with 02, 2 registers, 4 names
      # and its clock.
      assert %{answered: 9, retries: 0, timeouts: 0} = latency(status, 1)
    end

    test "an Elite 440 that refuses its merged identity request is read a register at a time",
         ctx do
      status = start_440!([refused_spans: [{{1, 0, 25}, 2}]], ctx)

      assert [%Reading{unit_id: 1} | _] = await_unit!(1, &match?([%Reading{} | _], &1))
      :ok = eventually!(fn -> latency(status, 1) != nil end)
      # The refused request, its two reads alone, the unit setting, 2 registers, 4 names
      # and its clock.
      assert %{answered: 11, retries: 0, timeouts: 0} = latency(status, 1)
    end

    # An Elite 440 at unit 1 with no unit setting, alone on its endpoint.
    defp start_440!(faults, ctx) do
      profile = Simulator.Profile.load!("elite_440")

      no_unit =
        1 |> Simulator.Meter.new(profile) |> Simulator.Meter.identify(:energy_unit, :absent)

      {sim, port} = start_chain!(:tcp, [no_unit])
      :ok = Simulator.faults(sim, faults)

      start_with_status!(
        [endpoint(port, "tcp", [meter(1, "elite_440")])],
        &DateTime.utc_now/0,
        ctx.tmp_dir
      )
    end

    test "each meter's day is logged when the UTC day ends", ctx do
      {_sim, port} = start_sim!(:tcp)
      agent = start_supervised!({Agent, fn -> ~U[2026-11-13 23:59:59Z] end})
      clock = fn -> Agent.get(agent, & &1) end
      endpoints = [endpoint(port, "tcp", [meter(1, "elite_440")], %{"interval_ms" => 5})]

      {_, log} =
        with_log(fn ->
          start_with_status!(endpoints, clock, ctx.tmp_dir)
          assert [%Reading{timestamp: ~U[2026-11-13 23:59:59Z]} | _] = recorded!()
          Agent.update(agent, fn _ -> ~U[2026-11-14 00:00:01Z] end)
          await_unit!(1, &match?([%Reading{timestamp: ~U[2026-11-14 00:00:01Z]} | _], &1))
          Agent.update(agent, fn _ -> ~U[2026-11-14 00:00:02Z] end)
          recorded!()
        end)

      prefix = "alavi poller 127.0.0.1:#{port} unit 1: latency, day ended, "

      assert [_one] =
               Regex.scan(
                 ~r/#{prefix}2026-11-13 UTC: \d+ answered \(0 on a retry\), 0 timed out; p50 \d+ ms/,
                 log
               )

      refute log =~ "#{prefix}2026-11-14"
    end

    test "each meter's day is recorded to the sink when the UTC day ends, under the poller's start",
         ctx do
      {_sim, port} = start_sim!(:tcp)
      agent = start_supervised!({Agent, fn -> ~U[2026-11-13 23:59:59Z] end})
      clock = fn -> Agent.get(agent, & &1) end
      meters = [meter(1, "elite_440"), meter(3, "elite_500")]
      endpoints = [endpoint(port, "tcp", meters, %{"interval_ms" => 5})]

      start_with_status!(endpoints, clock, ctx.tmp_dir)
      # Both meters must have a day before it ends: a meter not yet read has none.
      await_unit!(3, &match?([%Reading{timestamp: ~U[2026-11-13 23:59:59Z]} | _], &1))
      Agent.update(agent, fn _ -> ~U[2026-11-14 00:00:01Z] end)

      assert_receive {:latency, days}, 2_000
      assert Enum.map(days, & &1.unit_id) == [1, 3]

      for day <- days do
        assert %LatencyDay{
                 endpoint: %{host: "127.0.0.1", port: ^port},
                 date: ~D[2026-11-13],
                 poller_started_at: ~U[2026-11-13 23:59:59Z],
                 buckets_version: 1,
                 retries: 0,
                 timeouts: 0
               } = day

        assert length(day.buckets) == length(Latency.bounds()) + 1
        assert Enum.sum(day.buckets) > 0 and is_integer(day.max_ms)
      end

      refute_receive {:latency, _days}, 100
    end
  end

  describe "late replies" do
    test "a reply that comes after its request timed out is skipped, and counted late on its unit's day" do
      {sim, port} = start_sim!(:tcp)
      Simulator.faults(sim, delay_ms: 150)
      endpoints = [endpoint(port, "tcp", [meter(1, "elite_440")], %{"timeout_ms" => 100})]
      pollers = start_pollers!(endpoints, fn -> ~U[2026-11-14 10:00:00Z] end)
      Process.sleep(1_000)

      {:ok, log} = with_log(fn -> Alavi.Pollers.log_latency(pollers, 1_000) end)
      assert_receive {:latency, [%LatencyDay{unit_id: 1, late: %{data: late}} = day]}
      assert late > 0 and day.timeouts > 0
      assert log =~ ~r/unit 1: latency, before stopping, .*; late #{late} data/
    end
  end

  describe "Pollers.log_latency/2" do
    test "logs every poller's day so far, and passes over one that does not answer" do
      {_sim, port} = start_sim!(:tcp)
      {slow_sim, slow} = start_sim!(:tcp)
      Simulator.faults(slow_sim, delay_ms: 300)

      endpoints = [
        endpoint(port, "tcp", [meter(1, "elite_440"), meter(3, "elite_500")]),
        endpoint(slow, "tcp", [meter(2, "elite_440")], %{"timeout_ms" => 1_000})
      ]

      pollers = start_pollers!(endpoints, fn -> ~U[2026-11-14 10:00:00Z] end)
      await_unit!(3, &match?([%Reading{} | _], &1))

      {:ok, log} = with_log(fn -> Alavi.Pollers.log_latency(pollers, 100) end)

      for unit <- [1, 3] do
        assert log =~
                 ~r/alavi poller 127.0.0.1:#{port} unit #{unit}: latency, before stopping, 2026-11-14 UTC: \d+ answered/
      end

      refute log =~ "127.0.0.1:#{slow}"
      assert_receive {:latency, days}
      assert [%LatencyDay{unit_id: 1}, %LatencyDay{unit_id: 3}] = days
      assert Enum.all?(days, &match?(%LatencyDay{date: ~D[2026-11-14]}, &1))
      refute_received {:latency, _days}
    end
  end

  describe "Pollers.start_link/1" do
    test "never connects to an endpoint polled by another system" do
      {:ok, listen} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, active: false)
      {:ok, other_port} = :inet.port(listen)
      {_sim, port} = start_sim!(:tcp)

      sup =
        start_pollers!([
          endpoint(other_port, "tcp", [meter(1, "elite_440", %{"serial" => "OTHER-1"})], %{
            "polled_by_other_system" => true,
            "interval_ms" => 1
          }),
          endpoint(port, "tcp", [meter(1, "elite_440")], %{
            "interval_ms" => 5,
            "timeout_ms" => 1_000
          })
        ])

      for _ <- 1..5, do: assert([%Reading{endpoint: %{port: ^port}} | _] = recorded!())
      assert {:error, :timeout} = :gen_tcp.accept(listen, 0)

      running = for {_, pid, _, _} <- Supervisor.which_children(sup), is_pid(pid), do: pid
      assert length(running) == 1
    end

    test "endpoints are polled in parallel: a slow chain does not hold up another" do
      {slow, slow_port} = start_sim!(:tcp)
      Simulator.faults(slow, delay_ms: 300)
      {_sim, port} = start_sim!(:tcp)

      start_pollers!([
        endpoint(slow_port, "tcp", [meter(1, "elite_440", %{"serial" => "SLOW-1"})], %{
          "timeout_ms" => 1_000
        }),
        endpoint(port, "tcp", [meter(1, "elite_440")])
      ])

      assert [%Reading{endpoint: %{port: ^port}} | _] = recorded!(250)
    end
  end

  describe "retire/2" do
    test "a read on demand queued before is run, one asked after is refused, then it stops" do
      {slow, port} = start_sim!(:tcp)
      Simulator.faults(slow, delay_ms: 30)
      meters = [meter(1, "elite_440"), meter(2, "elite_440"), meter(3, "elite_500")]

      sup =
        start_pollers!([
          endpoint(port, "tcp", meters, %{"interval_ms" => 86_400_000, "timeout_ms" => 1_000})
        ])

      assert [%Reading{unit_id: 1} | _] = recorded!()
      [{_id, pid}] = Alavi.Pollers.pollers(sup)
      ref = Process.monitor(pid)
      assert {:ok, read} = Alavi.Pollers.read_now(sup, {"127.0.0.1", port}, [3], "before")
      Alavi.Poller.retire(pid, :removed)

      assert Alavi.Pollers.read_now(sup, {"127.0.0.1", port}, [1], "after") ==
               {:error, :retiring}

      assert_receive {:alavi_read, ^read, [%Reading{unit_id: 3, request_id: "before"} | _]}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
      assert Alavi.Pollers.pollers(sup) == [{{Alavi.Poller, "127.0.0.1", port}, :undefined}]
    end

    test "its latency so far is logged and recorded as it stops" do
      {_sim, port} = start_sim!(:tcp)
      sup = start_pollers!([endpoint(port, "tcp", [meter(1, "elite_440")])])
      recorded!()
      [{_id, pid}] = Alavi.Pollers.pollers(sup)

      {_down, log} =
        with_log(fn ->
          ref = Process.monitor(pid)
          Alavi.Poller.retire(pid, :replaced)
          assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
        end)

      assert log =~ "latency, before stopping"
      assert log =~ "stopped at a round boundary"
      assert_receive {:latency, [%LatencyDay{unit_id: 1}]}
    end
  end
end
