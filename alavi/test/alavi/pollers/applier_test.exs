defmodule Alavi.Pollers.ApplierTest do
  use ExUnit.Case, async: true

  import Alavi.PollerCase

  alias Alavi.{Config, ConfigKeeper, Poller, Pollers, Reading}
  alias Alavi.Config.Digest

  @moduletag :capture_log
  @moduletag :tmp_dir

  defp digest!(document) do
    {:ok, digest} = Digest.digest(document)
    digest
  end

  # A keeper started from `start`, serving whatever `served` holds when asked.
  defp keeper!(dir, start) do
    {:ok, config} = Config.parse(start, profiles())
    {:ok, served} = Agent.start_link(fn -> {:error, "nothing served yet"} end)

    opts = [
      config: config,
      digest: digest!(start),
      profiles: profiles(),
      dir: dir,
      fetch: fn -> Agent.get(served, & &1) end,
      status: no_status()
    ]

    {start_supervised!({ConfigKeeper, opts}), served}
  end

  # The keeper applies `document`, as on a server's answer naming it.
  defp apply!({keeper, served}, document) do
    Agent.update(served, fn _ -> {:ok, document} end)
    :ok = ConfigKeeper.answered(keeper, digest!(document))
    %{digest: digest} = ConfigKeeper.report(keeper)
    ^digest = digest!(document)
  end

  defp pollers!({keeper, _served}) do
    opts = [
      config: {:keeper, keeper},
      sink: {Alavi.TestSink, self()},
      clock: &DateTime.utc_now/0,
      raw_log: raw_log(),
      status: no_status(),
      selectors_dir: selectors_dir!()
    ]

    start_supervised!({Pollers, opts})
  end

  defp running(sup),
    do: Map.new(Pollers.pollers(sup), fn {{Poller, _, port}, pid} -> {port, pid} end)

  defp restarted?(sup, port, before) do
    pid = running(sup)[port]
    is_pid(pid) and pid != before[port]
  end

  # The endpoint and copy window the poller at `port` was started with.
  defp started(sup, port) do
    {:ok, %{start: {Poller, :start_link, [opts]}}} =
      :supervisor.get_childspec(sup, {Poller, "127.0.0.1", port})

    {Keyword.fetch!(opts, :endpoint), Keyword.fetch!(opts, :copy_window)}
  end

  defp at(port, meters, changes \\ %{}),
    do: endpoint(port, "tcp", meters, Map.merge(%{"interval_ms" => 50}, changes))

  # Sink messages until one from `port` satisfies `pred`.
  defp from!(port, pred \\ fn _events -> true end, tries \\ 400) do
    events = recorded!()

    cond do
      match?([%{endpoint: %{port: ^port}} | _], events) and pred.(events) -> events
      tries > 1 -> from!(port, pred, tries - 1)
      true -> flunk("nothing from port #{port}")
    end
  end

  defp flush do
    receive do
      {:recorded, _events} -> flush()
    after
      0 -> :ok
    end
  end

  defp none_from!(port, ms), do: none_until!(port, System.monotonic_time(:millisecond) + ms)

  defp none_until!(port, deadline) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:recorded, [%{endpoint: %{port: ^port}} | _]} -> flunk("port #{port} still polled")
      {:recorded, _events} -> none_until!(port, deadline)
    after
      left -> :ok
    end
  end

  # No serial expected: the simulators' meters all report the same ones.
  defp unit(unit_id, profile), do: unit_id |> meter(profile) |> Map.delete("serial")

  describe "start_link/1" do
    test "unchanged pollers carry on, new ones start, removed ones stop, changed ones restart with their settings",
         %{tmp_dir: dir} do
      [{_, same}, {_, changed}, {_, removed}, {_, added}] = for _ <- 1..4, do: start_sim!(:tcp)

      start =
        document(
          [at(same, [unit(1, "elite_440")]), at(changed, [unit(1, "elite_440")])] ++
            [at(removed, [unit(1, "elite_440")])]
        )

      keeper = keeper!(dir, start)
      sup = pollers!(keeper)
      for port <- [same, changed, removed], do: from!(port)
      before = running(sup)

      apply!(
        keeper,
        document([
          at(same, [unit(1, "elite_440")]),
          at(changed, [unit(1, "elite_440"), unit(2, "elite_440")]),
          at(added, [unit(3, "elite_500")])
        ])
      )

      from!(added)
      from!(changed, &match?([%Reading{unit_id: 2} | _], &1))
      :ok = eventually!(fn -> not Map.has_key?(running(sup), removed) end)
      after_ = running(sup)

      assert after_[same] == before[same]
      assert is_pid(after_[changed]) and after_[changed] != before[changed]
      refute Process.alive?(before[removed])
      flush()
      none_from!(removed, 300)
    end

    test "a change to an endpoint's copy restarts its poller alone; one to the copy window, every poller",
         %{tmp_dir: dir} do
      [{_, copying}, {_, other}] = for _ <- 1..2, do: start_sim!(:tcp)

      endpoints = fn copy ->
        [
          at(copying, [unit(1, "elite_440")], %{"copy" => copy}),
          at(other, [unit(1, "elite_440")])
        ]
      end

      keeper = keeper!(dir, document(endpoints.(false)))
      sup = pollers!(keeper)
      for port <- [copying, other], do: from!(port)
      start = running(sup)

      apply!(keeper, document(endpoints.(true)))
      :ok = eventually!(fn -> restarted?(sup, copying, start) end)
      switched = running(sup)

      assert switched[other] == start[other]
      assert {%{copy: true}, %{start: ~T[02:00:00]}} = started(sup, copying)

      night = %{"start" => "23:30", "end" => "00:30"}
      apply!(keeper, %{document(endpoints.(true)) | "copy_window" => night})

      :ok = eventually!(fn -> Enum.all?([copying, other], &restarted?(sup, &1, switched)) end)

      assert {%{copy: false}, %{start: ~T[23:30:00], end: ~T[00:30:00]}} = started(sup, other)
      from!(other)
    end

    test "a poller removed mid-round finishes the round, then stops", %{tmp_dir: dir} do
      {slow, port} = start_sim!(:tcp)
      {_sim, other} = start_sim!(:tcp)
      Simulator.faults(slow, delay_ms: 40)
      meters = [unit(1, "elite_440"), unit(2, "elite_440"), unit(3, "elite_500")]

      keeper =
        keeper!(
          dir,
          document([at(port, meters, %{"interval_ms" => 60_000, "timeout_ms" => 1_000})])
        )

      sup = pollers!(keeper)
      assert [%Reading{unit_id: 1} | _] = from!(port)
      pid = running(sup)[port]
      ref = Process.monitor(pid)
      apply!(keeper, document([at(other, [unit(1, "elite_440")])]))

      assert [%Reading{unit_id: 2} | _] = from!(port)
      assert [%Reading{unit_id: 3} | _] = from!(port)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end

    test "a poller removed between rounds stops at once, starting no other", %{tmp_dir: dir} do
      {_sim, port} = start_sim!(:tcp)
      {_sim, other} = start_sim!(:tcp)

      keeper =
        keeper!(dir, document([at(port, [unit(1, "elite_440")], %{"interval_ms" => 60_000})]))

      sup = pollers!(keeper)
      from!(port)
      pid = running(sup)[port]
      ref = Process.monitor(pid)

      apply!(keeper, document([at(other, [unit(1, "elite_440")])]))

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
      flush()
      none_from!(port, 200)
    end

    test "pollers started after a config was applied poll that config, not the one the keeper started from",
         %{tmp_dir: dir} do
      {_sim, port} = start_sim!(:tcp)
      {_sim, other} = start_sim!(:tcp)
      keeper = keeper!(dir, document([at(port, [unit(1, "elite_440")])]))
      apply!(keeper, document([at(other, [unit(1, "elite_440")])]))

      sup = pollers!(keeper)

      assert [%Reading{endpoint: %{port: ^other}} | _] = recorded!()
      assert Map.keys(running(sup)) == [other]
    end

    test "an applier started again settles the pollers to the config applied, whenever it came",
         %{tmp_dir: dir} do
      {_sim, port} = start_sim!(:tcp)
      {_sim, other} = start_sim!(:tcp)
      keeper = keeper!(dir, document([at(port, [unit(1, "elite_440")])]))
      sup = pollers!(keeper)
      from!(port)

      [{Pollers.Applier, applier, _, _}] = applier_child(sup)
      Process.exit(applier, :kill)
      apply!(keeper, document([at(other, [unit(1, "elite_440")])]))

      from!(other)
      :ok = eventually!(fn -> Map.keys(running(sup)) == [other] end)
      assert [{Pollers.Applier, restarted, _, _}] = applier_child(sup)
      assert restarted != applier
    end
  end

  defp applier_child(sup),
    do:
      for(
        {Pollers.Applier, pid, _, _} = child <- Supervisor.which_children(sup),
        is_pid(pid),
        do: child
      )
end
