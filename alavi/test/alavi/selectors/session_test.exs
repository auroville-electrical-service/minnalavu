defmodule Alavi.Selectors.SessionTest do
  use ExUnit.Case, async: true

  import Alavi.PollerCase, only: [start_sim!: 2]
  import ExUnit.CaptureLog

  alias Alavi.Modbus.Client
  alias Alavi.Selectors.{Record, Session, Store}

  @moduletag :tmp_dir

  # Unit 3 of the simulated chain is an Elite 500: history 900, snapshot 1500.
  @history 900
  @snapshot 1500
  @selectors [history: 6, snapshot: 52]

  # Two connections: a test that drops one and connects again would otherwise
  # race the simulator, which, like a one-connection gateway, refuses the new
  # one until it has seen the old one close.
  setup %{tmp_dir: dir} do
    {sim, port} = start_sim!(:tcp, max_connections: 2)
    {:ok, client} = Client.connect("127.0.0.1", port, :tcp, timeout: 200, max_timeouts: 3)
    %{sim: sim, client: client, dir: dir, endpoint: %{host: "127.0.0.1", port: port}}
  end

  defp open(ctx, selectors \\ @selectors),
    do: Session.open(ctx.client, ctx.dir, ctx.endpoint, 3, "elite_500", selectors)

  defp selector(client, address) do
    {:ok, [value], client} = Client.read(client, 3, :holding, address, 1)
    {value, client}
  end

  defp owed(ctx), do: Store.owed(ctx.dir, ctx.endpoint)

  describe "open/6" do
    test "saves each selector's value to disk, writing nothing", ctx do
      :ok = Simulator.select(ctx.sim, 3, @snapshot, 9)
      assert {:ok, _session, client} = open(ctx)

      assert {:ok, %Record{unit_id: 3, model: "elite_500", selectors: selectors}} = owed(ctx)

      assert selectors == [
               %{name: :history, value: 0, bound: 6},
               %{name: :snapshot, value: 9, bound: 52}
             ]

      assert {9, _} = selector(client, @snapshot)
    end

    test "no session opens while a restore is owed, readable or not", ctx do
      {:ok, _session, client} = open(ctx)

      log =
        capture_log(fn ->
          assert {:error, :restore_owed, client} = open(%{ctx | client: client})
          File.write!(Path.join(ctx.dir, "127.0.0.1_#{ctx.endpoint.port}.restore"), "{")
          assert {:error, :restore_owed, _} = open(%{ctx | client: client})
        end)

      assert log =~ ":restore_owed"
    end

    test "a selector not where the last session left it refuses the session, logged, nothing saved",
         ctx do
      {:ok, session, client} = open(ctx)
      {:ok, client} = Session.set(session, client, :history, 4, 6)
      {:ok, :restored, client} = Session.close(session, client)

      :ok = Simulator.select(ctx.sim, 3, @history, 2)

      log =
        capture_log(fn ->
          assert {:error, {:moved, :history, 2, 0}, _} = open(%{ctx | client: client})
        end)

      assert log =~ "no session opened, nothing written"
      assert owed(ctx) == :none
      assert {2, _} = selector(client, @history)
    end

    test "with nothing left before, the values found are taken as the ones to put back", ctx do
      :ok = Simulator.select(ctx.sim, 3, @history, 2)
      assert {:ok, _session, _client} = open(ctx)
      assert {:ok, %Record{selectors: [%{name: :history, value: 2} | _]}} = owed(ctx)
    end

    test "a value the allowlist would not let us write back refuses the session", ctx do
      :ok = Simulator.select(ctx.sim, 3, @snapshot, 60)
      capture_log(fn -> assert {:error, {:not_restorable, :snapshot, 60}, _} = open(ctx) end)
      assert owed(ctx) == :none
    end

    test "only the model's allowlisted selectors, each once, and at least one", ctx do
      for selectors <- [[], [clock: 1], [history: 6, history: 6]] do
        capture_log(fn -> assert {:error, :not_allowed, _} = open(ctx, selectors) end)
      end

      capture_log(fn ->
        assert {:error, :not_allowed, _} =
                 Session.open(ctx.client, ctx.dir, ctx.endpoint, 3, "elite_300", history: 6)
      end)

      assert owed(ctx) == :none
    end

    test "a left record that cannot be read refuses the session", ctx do
      File.write!(Path.join(ctx.dir, "127.0.0.1_#{ctx.endpoint.port}.left"), "nope")
      capture_log(fn -> assert {:error, {:left_unreadable, _}, _} = open(ctx) end)
      assert owed(ctx) == :none
    end

    test "a selector that cannot be read saves nothing", ctx do
      Simulator.faults(ctx.sim, refused_reads: [{{3, @snapshot}, 4}])
      assert {:error, {:read, :snapshot, {:exception, 4}}, _} = open(ctx)
      assert owed(ctx) == :none
    end
  end

  describe "set/5" do
    test "writes a selector of the session and reads it back", ctx do
      {:ok, session, client} = open(ctx)
      assert {:ok, client} = Session.set(session, client, :snapshot, 51, 52)
      assert {51, _} = selector(client, @snapshot)
    end

    test "writes nothing once the saved record is gone or changed", ctx do
      {:ok, session, client} = open(ctx)
      :ok = Store.clear(ctx.dir, ctx.endpoint)
      assert {:error, :not_owed, client} = Session.set(session, client, :history, 3, 6)
      assert {0, client} = selector(client, @history)

      :ok = Store.owe(ctx.dir, other_record(ctx))
      assert {:error, :not_owed, client} = Session.set(session, client, :history, 3, 6)
      assert {0, _} = selector(client, @history)
    end

    test "only the session's selectors, in range", ctx do
      {:ok, session, client} = open(ctx, history: 6)
      assert {:error, :not_in_session, client} = Session.set(session, client, :snapshot, 1, 52)
      assert {:error, :out_of_range, client} = Session.set(session, client, :history, 7, 6)
      assert {0, _} = selector(client, @snapshot)
      assert {0, _} = selector(client, @history)
    end

    test "a write that does not read back is an error", ctx do
      {:ok, session, client} = open(ctx)
      Simulator.faults(ctx.sim, lost_writes: [{3, @history}])

      assert {:error, {:read_back, :history, 3, 0}, _} =
               Session.set(session, client, :history, 3, 6)
    end
  end

  describe "restore/3" do
    test "close/2 puts every selector back, reads it back, records it as left, clears the record",
         ctx do
      :ok = Simulator.select(ctx.sim, 3, @snapshot, 9)
      {:ok, session, client} = open(ctx)
      {:ok, client} = Session.set(session, client, :history, 4, 6)
      {:ok, client} = Session.set(session, client, :snapshot, 0, 52)

      assert {:ok, :restored, client} = Session.close(session, client)
      assert {0, client} = selector(client, @history)
      assert {9, _} = selector(client, @snapshot)
      assert owed(ctx) == :none

      assert Store.left(ctx.dir, ctx.endpoint) ==
               {:ok, %{{3, "elite_500", :history} => 0, {3, "elite_500", :snapshot} => 9}}
    end

    test "after a crash, the record alone puts the selectors back, on a new connection", ctx do
      {:ok, session, client} = open(ctx)
      {:ok, client} = Session.set(session, client, :history, 5, 6)
      Client.close(client)

      {:ok, client} =
        Client.connect("127.0.0.1", ctx.endpoint.port, :tcp, timeout: 200, max_timeouts: 3)

      assert {:ok, :restored, client} = Session.restore(client, ctx.dir, ctx.endpoint)
      assert {0, _} = selector(client, @history)
      assert owed(ctx) == :none
      assert {:ok, :none, _} = Session.restore(client, ctx.dir, ctx.endpoint)
    end

    test "a write back that does not read back keeps the record", ctx do
      {:ok, session, client} = open(ctx)
      {:ok, client} = Session.set(session, client, :history, 5, 6)
      Simulator.faults(ctx.sim, lost_writes: [{3, @history}])

      assert {:error, {:read_back, :history, 0, 5}, client} = Session.close(session, client)
      assert {:ok, %Record{}} = owed(ctx)
      assert Store.left(ctx.dir, ctx.endpoint) == {:ok, %{}}

      Simulator.clear_faults(ctx.sim)
      assert {:ok, :restored, _} = Session.restore(client, ctx.dir, ctx.endpoint)
    end

    test "a refused write back keeps the record", ctx do
      {:ok, session, client} = open(ctx)
      {:ok, client} = Session.set(session, client, :history, 5, 6)
      Simulator.faults(ctx.sim, refused_reads: [{{3, @history}, 4}])

      assert {:error, {:read, :history, {:exception, 4}}, _} = Session.close(session, client)
      assert {:ok, %Record{}} = owed(ctx)
    end

    test "an unreadable record is owed with values unknown: nothing is written, nothing cleared",
         ctx do
      path = Path.join(ctx.dir, "127.0.0.1_#{ctx.endpoint.port}.restore")
      File.write!(path, "{\"format\"")
      :ok = Simulator.select(ctx.sim, 3, @history, 5)

      assert {:error, {:unreadable, {:unreadable, ^path, _}}, client} =
               Session.restore(ctx.client, ctx.dir, ctx.endpoint)

      assert {5, _} = selector(client, @history)
      assert File.read!(path) == "{\"format\""
    end
  end

  defp other_record(ctx) do
    %Record{
      endpoint: ctx.endpoint,
      unit_id: 3,
      model: "elite_500",
      selectors: [%{name: :history, value: 1, bound: 6}]
    }
  end
end
