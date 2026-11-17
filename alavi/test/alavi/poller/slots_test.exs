defmodule Alavi.Poller.SlotsTest do
  use ExUnit.Case, async: true

  import Alavi.PollerCase

  alias Alavi.{LocalTime, MissedRead, Reading}

  @moduletag :capture_log

  @quarter 15 * 60_000
  @day 86_400_000

  # The UTC instant at which the collector's local wall clock reads `local`.
  defp utc(local) do
    [utc | _] = :calendar.local_time_to_universal_time_dst(NaiveDateTime.to_erl(local))
    DateTime.from_naive!(NaiveDateTime.from_erl!(utc), "Etc/UTC")
  end

  defp clock!(local) do
    agent = start_supervised!({Agent, fn -> utc(local) end}, id: make_ref())
    {agent, fn -> Agent.get(agent, & &1) end}
  end

  defp set!(agent, local), do: Agent.update(agent, fn _ -> utc(local) end)

  # The test process is the status, so it sees each round's end and each
  # schedule: one at the start, which is returned, then one after each round.
  defp poll!(port, clock, changes, id \\ :pollers, meters \\ [meter(1, "elite_440")]) do
    endpoints = [endpoint(port, "tcp", meters, changes)]

    opts = [
      config: config!(endpoints),
      sink: {Alavi.TestSink, self()},
      clock: clock,
      raw_log: raw_log(),
      status: self(),
      selectors_dir: selectors_dir!(),
      recheck_ms: 20
    ]

    start_supervised!({Alavi.Pollers, opts}, id: id)
    schedule!()
  end

  # A round's events, and the schedule after it.
  defp round! do
    assert_receive {:"$gen_cast", {:round, events}}, 2_000
    {events, schedule!()}
  end

  defp no_round!(ms), do: refute_receive({:"$gen_cast", {:round, _}}, ms)

  defp schedule! do
    assert_receive {:"$gen_cast", {:schedule, _endpoint, %{1 => schedule}}}, 2_000
    schedule
  end

  defp local_at([%{timestamp: at} | _]),
    do: at |> LocalTime.of() |> NaiveDateTime.truncate(:second)

  defp read?(events), do: Enum.any?(events, &match?(%Reading{}, &1))

  defp until_read!(tries \\ 10) do
    {events, schedule} = round!()

    cond do
      read?(events) -> schedule
      tries > 1 -> until_read!(tries - 1)
      true -> flunk("no round read the meter")
    end
  end

  defp at!, do: round!() |> elem(0) |> local_at()

  describe "start_link/1" do
    test "rounds land on the slots of the local wall clock, and a restart polls at once" do
      {_sim, port} = start_sim!(:tcp)
      {agent, clock} = clock!(~N[2026-11-17 10:07:00])
      start = poll!(port, clock, %{"interval_ms" => @quarter})

      assert start.next_due_at =~ ~r/^2026-11-17T10:00:00[+-]\d\d:\d\d$/
      assert {events, %{next_due_at: "2026-11-17T10:15:00" <> _, retrying: false}} = round!()
      assert local_at(events) == ~N[2026-11-17 10:07:00]

      set!(agent, ~N[2026-11-17 10:14:59])
      no_round!(200)
      set!(agent, ~N[2026-11-17 10:15:00])
      assert at!() == ~N[2026-11-17 10:15:00]

      stop_supervised!(:pollers)
      set!(agent, ~N[2026-11-17 10:20:00])
      poll!(port, clock, %{"interval_ms" => @quarter}, :again)
      assert at!() == ~N[2026-11-17 10:20:00]

      set!(agent, ~N[2026-11-17 10:29:59])
      no_round!(200)
      set!(agent, ~N[2026-11-17 10:30:00])
      assert at!() == ~N[2026-11-17 10:30:00]
      no_round!(200)
    end

    test "no round is doubled or skipped across a clock set back, and slots passed forward come to one" do
      {_sim, port} = start_sim!(:tcp)
      {agent, clock} = clock!(~N[2026-11-17 10:07:00])
      poll!(port, clock, %{"interval_ms" => @quarter})
      at!()

      set!(agent, ~N[2026-11-17 09:50:00])
      no_round!(200)
      set!(agent, ~N[2026-11-17 10:14:59])
      no_round!(200)
      set!(agent, ~N[2026-11-17 10:15:00])
      assert at!() == ~N[2026-11-17 10:15:00]
      no_round!(200)

      set!(agent, ~N[2026-11-17 13:40:00])
      assert at!() == ~N[2026-11-17 13:40:00]
      no_round!(300)
      set!(agent, ~N[2026-11-17 13:45:00])
      assert at!() == ~N[2026-11-17 13:45:00]
    end

    test "a slot boundary at local midnight starts the next date's first slot" do
      {_sim, port} = start_sim!(:tcp)
      {agent, clock} = clock!(~N[2026-11-17 23:30:00])
      poll!(port, clock, %{"interval_ms" => 6 * 3_600_000})
      at!()

      set!(agent, ~N[2026-11-17 23:59:59])
      no_round!(200)
      set!(agent, ~N[2026-11-18 00:00:00])
      assert {events, %{next_due_at: "2026-11-18T06:00:00" <> _}} = round!()
      assert local_at(events) == ~N[2026-11-18 00:00:00]
    end

    for {name, faults} <- [
          {"a meter that does not answer", [silent_units: [1]]},
          {"a meter whose requests close the connection", [dropped_requests: [{1, 0}]]},
          {"a meter that stays busy", [busy: true]}
        ] do
      test "#{name} is retried at its retry interval, then back on its slots once it answers" do
        {sim, port} = start_sim!(:tcp)
        :ok = Simulator.faults(sim, unquote(faults))
        {_agent, clock} = clock!(~N[2026-11-17 10:07:00])
        poll!(port, clock, %{"interval_ms" => @day, "retry_ms" => 300})

        assert {events, %{retrying: true, next_due_at: "2026-11-17T10:07:00" <> _}} = round!()
        refute read?(events)
        missed = System.monotonic_time(:millisecond)

        assert {events, %{retrying: true}} = round!()
        refute read?(events)
        assert System.monotonic_time(:millisecond) - missed >= 300

        Simulator.clear_faults(sim)
        assert %{retrying: false, next_due_at: "2026-11-18T00:00:00" <> _} = until_read!()
        no_round!(700)
      end
    end

    test "a meter that answers only with exception replies is not retried before its slot" do
      {sim, port} = start_sim!(:tcp)
      :ok = Simulator.faults(sim, refused_reads: [{{1, 199}, 2}, {{1, 201}, 2}])
      {_agent, clock} = clock!(~N[2026-11-17 10:07:00])
      poll!(port, clock, %{"interval_ms" => @day, "retry_ms" => 300})

      assert {[_ | _] = events, %{retrying: false, next_due_at: "2026-11-18T00:00:00" <> _}} =
               round!()

      assert Enum.all?(events, &match?(%MissedRead{reason: {:exception, 2}}, &1))
      no_round!(700)
    end

    test "a meter that answers but is not the one configured is not retried before its slot" do
      {_sim, port} = start_sim!(:tcp)
      {_agent, clock} = clock!(~N[2026-11-17 10:07:00])
      changes = %{"interval_ms" => @day, "retry_ms" => 300}
      poll!(port, clock, changes, :pollers, [meter(1, "elite_500")])

      assert {[%MissedRead{} | _] = events, %{retrying: false}} = round!()
      refute read?(events)
      no_round!(700)
    end
  end
end
