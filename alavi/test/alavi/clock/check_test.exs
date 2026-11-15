defmodule Alavi.Clock.CheckTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Alavi.Clock.Check
  alias Alavi.{ClockCheck, FakeNtp, RefusingSink, TestSink}

  @start ~U[2026-11-01 00:00:04.000123Z]
  @server_at 1_793_491_208_215_003_051

  # The OS clock and monotonic time, moved only by `advance/3`. An advance
  # takes effect at the next read of monotonic time, which a watch makes
  # before it reads the OS clock, so no watch sees half of one.
  defp fake_time do
    start = %{os: @start, monotonic: 1_000_000, pending: []}
    {:ok, agent} = Agent.start_link(fn -> start end)

    monotonic = fn ->
      Agent.get_and_update(agent, fn t ->
        t = Enum.reduce(Enum.reverse(t.pending), %{t | pending: []}, &moved/2)
        {t.monotonic, t}
      end)
    end

    {agent, fn -> Agent.get(agent, & &1.os) end, monotonic}
  end

  defp moved({os_ms, monotonic_ms}, t),
    do: %{t | os: DateTime.add(t.os, os_ms, :millisecond), monotonic: t.monotonic + monotonic_ms}

  defp advance(agent, os_ms, monotonic_ms),
    do: Agent.update(agent, &%{&1 | pending: [{os_ms, monotonic_ms} | &1.pending]})

  defp answer(fields \\ []), do: fn request -> {:reply, FakeNtp.reply(request, fields)} end

  defp start!(servers, port, opts \\ []) do
    {agent, clock, monotonic} = fake_time()

    defaults = [
      servers: servers,
      port: port,
      sink: {TestSink, self()},
      status: self(),
      clock: clock,
      monotonic: monotonic,
      timeout_ms: 100,
      watch_ms: 10,
      step_ms: 2_000,
      day_ms: 1_000_000_000,
      step_gap_ms: 600_000
    ]

    start_supervised!({Check, Keyword.merge(defaults, opts)})
    agent
  end

  defp recorded! do
    assert_receive {:recorded, checks}, 1_000
    checks
  end

  describe "start_link/1" do
    test "at start, one query; the answer is recorded with the server's times and fields" do
      port = FakeNtp.start!(answer(received: @server_at, sent: @server_at + 44_261))
      start!(["127.0.0.1"], port)

      assert_receive {:ntp_request, {127, 0, 0, 1}, <<0x23, _::binary-47>>}

      assert [%ClockCheck{trigger: :start, server: "127.0.0.1", t1: @start, t4: @start} = c] =
               recorded!()

      assert {:answered,
              %{address: {127, 0, 0, 1}, stratum: 2, leap: 0, reference_id: 0xC0000283} = a} =
               c.outcome

      assert {a.t2, a.t3} == {@server_at, @server_at + 44_261}
      assert_receive {:"$gen_cast", {:clock_check, ^c}}
      refute_receive {:ntp_request, _, _}, 50
    end

    test "servers are asked in order until one answers, and every query is recorded" do
      port = FakeNtp.start!(fn _ -> :drop end, {127, 0, 0, 2})
      ^port = FakeNtp.start!(answer(), {127, 0, 0, 3}, port)
      ^port = FakeNtp.start!(answer(), {127, 0, 0, 4}, port)
      start!(["127.0.0.2", "127.0.0.3", "127.0.0.4"], port)

      assert [
               %ClockCheck{server: "127.0.0.2", outcome: :timeout},
               %ClockCheck{server: "127.0.0.3", outcome: {:answered, _}} = answered
             ] = recorded!()

      assert_receive {:"$gen_cast", {:clock_check, ^answered}}
      refute_received {:ntp_request, {127, 0, 0, 4}, _}
    end

    test "a server that is not there, or a name that does not resolve, is unreachable" do
      port = FakeNtp.start!(fn _ -> :drop end, {127, 0, 0, 5})

      log =
        capture_log(fn ->
          start!(["127.0.0.6", "no-such-host.invalid"], port)

          assert [
                   %ClockCheck{server: "127.0.0.6", outcome: :unreachable},
                   %ClockCheck{server: "no-such-host.invalid", outcome: :unreachable} = last
                 ] = recorded!()

          assert_receive {:"$gen_cast", {:clock_check, ^last}}
        end)

      assert log =~ "no-such-host.invalid does not resolve"
    end

    test "a reply that does not echo the request is invalid, and the next server asked" do
      port = FakeNtp.start!(answer(origin: <<1::64>>), {127, 0, 0, 7})
      ^port = FakeNtp.start!(answer(leap: 3), {127, 0, 0, 8}, port)
      ^port = FakeNtp.start!(answer(version: 3), {127, 0, 0, 9}, port)

      log =
        capture_log(fn ->
          start!(["127.0.0.7", "127.0.0.8", "127.0.0.9"], port)

          assert [%{outcome: :invalid}, %{outcome: :invalid}, %{outcome: :invalid}] =
                   recorded!()
        end)

      assert log =~ "originate timestamp"
      assert log =~ "leap indicator 3"
    end

    test "a kiss-o'-death keeps the address and code, and the next server is asked" do
      rate = 0x52415445
      port = FakeNtp.start!(answer(stratum: 0, leap: 3, reference_id: rate), {127, 0, 0, 10})
      ^port = FakeNtp.start!(answer(), {127, 0, 0, 11}, port)
      start!(["127.0.0.10", "127.0.0.11"], port)

      assert [
               %ClockCheck{outcome: {:kiss_of_death, {127, 0, 0, 10}, ^rate}},
               %ClockCheck{outcome: {:answered, _}}
             ] = recorded!()
    end

    test "a step of the OS clock beyond step_ms triggers a check; drift within it does not" do
      port = FakeNtp.start!(answer())
      agent = start!(["127.0.0.1"], port)
      assert [%{trigger: :start}] = recorded!()

      advance(agent, 61_900, 60_000)
      refute_receive {:recorded, _}, 100

      advance(agent, 57_000, 60_000)
      assert [%{trigger: :step}] = recorded!()
    end

    test "at most one step-triggered check per step_gap_ms; a step within it waits it out" do
      port = FakeNtp.start!(answer())
      agent = start!(["127.0.0.1"], port)
      assert [%{trigger: :start}] = recorded!()

      advance(agent, 3_000, 0)
      assert [%{trigger: :step}] = recorded!()

      advance(agent, -3_000, 0)
      refute_receive {:recorded, _}, 100

      advance(agent, 599_000, 599_000)
      refute_receive {:recorded, _}, 100

      advance(agent, 1_000, 1_000)
      assert [%{trigger: :step}] = recorded!()
      refute_receive {:recorded, _}, 100
    end

    test "a check every day_ms of monotonic time, whatever the OS clock says" do
      port = FakeNtp.start!(answer())
      agent = start!(["127.0.0.1"], port, day_ms: 5_000, step_ms: 1_000_000)
      assert [%{trigger: :start}] = recorded!()

      advance(agent, 0, 4_999)
      refute_receive {:recorded, _}, 100

      advance(agent, 100_000, 1)
      assert [%{trigger: :daily}] = recorded!()

      advance(agent, 0, 4_999)
      refute_receive {:recorded, _}, 100
      advance(agent, 0, 1)
      assert [%{trigger: :daily}] = recorded!()
    end

    test "a sink that refuses the checks is logged, and checks go on" do
      port = FakeNtp.start!(answer())

      log =
        capture_log(fn ->
          agent = start!(["127.0.0.1"], port, sink: {RefusingSink, self()})
          assert [%{trigger: :start}] = recorded!()
          advance(agent, 3_000, 0)
          assert [%{trigger: :step}] = recorded!()
        end)

      assert log =~ "1 clock checks not kept: :full"
    end
  end

  describe "options/1" do
    test "a release asks port 123, waits 5 s, watches every 60 s, a step beyond 2 s" do
      opts = Check.options(["pool.ntp.org"])

      assert %{
               servers: ["pool.ntp.org"],
               port: 123,
               timeout_ms: 5_000,
               watch_ms: 60_000,
               step_ms: 2_000,
               day_ms: 86_400_000,
               step_gap_ms: 600_000,
               name: Check
             } = Map.new(opts)

      assert %DateTime{microsecond: {_, 6}} = opts[:clock].()
    end
  end
end
