defmodule Alavi.RestoreTest do
  use ExUnit.Case, async: true

  import Alavi.PollerCase
  import ExUnit.CaptureLog

  alias Alavi.{MissedRead, Reading}
  alias Alavi.Selectors.{Record, Store}

  @history 520

  # A poller of unit 1 (an Elite 440) every 50 ms, its status cast to the test.
  defp start!(port, dir) do
    opts = [
      config: config!([endpoint(port, "tcp", [meter(1, "elite_440")], %{"interval_ms" => 50})]),
      sink: {Alavi.TestSink, self()},
      clock: &DateTime.utc_now/0,
      raw_log: raw_log(),
      status: self(),
      selectors_dir: dir
    ]

    start_supervised!({Alavi.Pollers, opts})
  end

  defp owe!(dir, port) do
    record = %Record{
      endpoint: %{host: "127.0.0.1", port: port},
      unit_id: 1,
      model: "elite_440",
      selectors: [%{name: :history, value: 0, bound: 6}]
    }

    :ok = Store.owe(dir, record)
  end

  # The next sink record or selectors status, whichever comes first.
  defp next! do
    receive do
      {:recorded, events} -> {:recorded, events}
      {:"$gen_cast", {:selectors, _endpoint, event}} -> {:selectors, event}
    after
      2_000 -> flunk("nothing recorded, no selectors status")
    end
  end

  defp until!(pred, tries \\ 200) do
    event = next!()

    cond do
      pred.(event) -> event
      tries > 1 -> until!(pred, tries - 1)
      true -> flunk("never happened")
    end
  end

  describe "start_link/1" do
    @describetag :tmp_dir

    test "a restore owed at start runs before the first round, and is cleared once read back",
         %{tmp_dir: dir} do
      {sim, port} = start_sim!(:tcp)
      :ok = Simulator.select(sim, 1, @history, 3)
      owe!(dir, port)

      log =
        capture_log(fn ->
          start!(port, dir)
          assert next!() == {:selectors, {:owed, "found at start", 0}}
          assert next!() == {:selectors, :restored}
          assert {:recorded, [%Reading{} | _]} = next!()
        end)

      assert log =~ "a selector restore is owed"
      assert log =~ "selectors restored and read back"
      assert Store.owed(dir, %{host: "127.0.0.1", port: port}) == :none

      assert Store.left(dir, %{host: "127.0.0.1", port: port}) ==
               {:ok, %{{1, "elite_440", :history} => 0}}
    end

    test "a failing restore is retried, the endpoint shown faulted, and polls go on as before",
         %{tmp_dir: dir} do
      {sim, port} = start_sim!(:tcp)
      :ok = Simulator.select(sim, 1, @history, 3)
      Simulator.faults(sim, lost_writes: [{1, @history}])
      owe!(dir, port)
      endpoint = %{host: "127.0.0.1", port: port}

      capture_log(fn ->
        start!(port, dir)

        assert {:selectors, {:owed, detail, 1}} =
                 until!(&match?({:selectors, {:owed, _, 1}}, &1))

        assert detail =~ "read_back"
        {:recorded, events} = until!(&match?({:recorded, _}, &1))
        assert Enum.all?(events, &match?(%Reading{request_id: nil}, &1))
        refute Enum.any?(events, &match?(%MissedRead{}, &1))
        until!(&match?({:selectors, {:owed, _, 3}}, &1))
        assert {:ok, %Record{}} = Store.owed(dir, endpoint)

        Simulator.clear_faults(sim)
        until!(&(&1 == {:selectors, :restored}))
      end)

      assert Store.owed(dir, endpoint) == :none
      assert Store.left(dir, endpoint) == {:ok, %{{1, "elite_440", :history} => 0}}
    end

    test "an unreadable record stays owed with values unknown, faulted, and polls go on",
         %{tmp_dir: dir} do
      {_sim, port} = start_sim!(:tcp)
      path = Path.join(dir, "127.0.0.1_#{port}.restore")
      File.write!(path, "{")

      capture_log(fn ->
        start!(port, dir)

        assert {:selectors, {:owed, detail, 1}} =
                 until!(&match?({:selectors, {:owed, _, 1}}, &1))

        assert detail =~ "unreadable"
        {:recorded, [%Reading{} | _]} = until!(&match?({:recorded, _}, &1))
        until!(&match?({:selectors, {:owed, _, 2}}, &1))
      end)

      assert File.read!(path) == "{"
    end
  end

  describe "retire/2" do
    @describetag :tmp_dir

    test "removed, it puts back the selectors owed before it stops, however long that takes",
         %{tmp_dir: dir} do
      {sim, port} = start_sim!(:tcp)
      :ok = Simulator.select(sim, 1, @history, 3)
      Simulator.faults(sim, lost_writes: [{1, @history}])
      owe!(dir, port)
      endpoint = %{host: "127.0.0.1", port: port}

      capture_log(fn ->
        sup = start!(port, dir)
        until!(&match?({:selectors, {:owed, _, 1}}, &1))
        [{_id, pid}] = Alavi.Pollers.pollers(sup)
        ref = Process.monitor(pid)
        Alavi.Poller.retire(pid, :removed)

        until!(&match?({:selectors, {:owed, _, 3}}, &1))
        refute_received {:DOWN, ^ref, _, _, _}
        Simulator.clear_faults(sim)
        until!(&(&1 == {:selectors, :restored}))
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
      end)

      assert Store.owed(dir, endpoint) == :none
    end

    test "replaced, it stops leaving the selectors owed, for its successor finds them at start",
         %{tmp_dir: dir} do
      {sim, port} = start_sim!(:tcp)
      :ok = Simulator.select(sim, 1, @history, 3)
      Simulator.faults(sim, lost_writes: [{1, @history}])
      owe!(dir, port)

      capture_log(fn ->
        sup = start!(port, dir)
        until!(&match?({:selectors, {:owed, _, 1}}, &1))
        [{_id, pid}] = Alavi.Pollers.pollers(sup)
        ref = Process.monitor(pid)
        Alavi.Poller.retire(pid, :replaced)
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
      end)

      assert {:ok, %Record{}} = Store.owed(dir, %{host: "127.0.0.1", port: port})
    end
  end
end
