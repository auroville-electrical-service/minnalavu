defmodule Alavi.CollectorTest do
  use ExUnit.Case, async: true

  import Alavi.PollerCase

  alias Alavi.{Buffer, Clock, Collector, MissedRead, Reading, Settings, Wire}
  alias Alavi.Buffer.Batch
  alias Alavi.Uplink.Target

  @moduletag :tmp_dir
  @moduletag :capture_log
  @contract Path.expand("../../../contract", __DIR__)
  @linux {:unix, :linux}

  defp start_collector!(dir, endpoints, uplink \\ :none) do
    name = :"buffer_#{System.unique_integer([:positive])}"

    buffer = [
      dir: dir,
      max_bytes: 1_000_000,
      max_batch_events: 1_000,
      clock_status: &Clock.unsynced/0,
      name: name
    ]

    opts = [
      config: config!(endpoints),
      buffer: buffer,
      clock: fn -> ~U[2026-11-01 00:00:00Z] end,
      uplink: uplink,
      raw_log: raw_log(),
      clock_status: :none
    ]

    {start_supervised!({Collector, opts}, id: :collector), name}
  end

  defp await_events!(buffer, n, tries \\ 100) do
    cond do
      Buffer.backlog(buffer).events >= n -> :ok
      tries > 0 -> Process.sleep(20) && await_events!(buffer, n, tries - 1)
      true -> flunk("buffer never held #{n} events")
    end
  end

  describe "start_link/1" do
    test "pollers write into the buffer, and a batch survives a restart of the collector", ctx do
      {_sim, port} = start_sim!(:tcp, missing_units: :gateway_error)
      meters = [meter(1, "elite_440"), meter(9, "elite_440"), meter(3, "elite_500")]
      endpoints = [endpoint(port, "tcp", meters)]

      {_collector, buffer} = start_collector!(ctx.tmp_dir, endpoints)
      :ok = await_events!(buffer, 8)
      {:ok, %Batch{events: events} = batch} = Buffer.take(buffer)

      assert Enum.map(events, & &1.unit_id) |> Enum.dedup() == [1, 9, 3]
      {readings, missed} = Enum.split_with(events, &match?(%Reading{}, &1))
      assert length(readings) == 6
      assert Enum.all?(missed, &match?(%MissedRead{unit_id: 9}, &1))
      assert hd(readings).value == Decimal.new("123456.000")

      :ok = stop_supervised(:collector)
      {_collector, buffer} = start_collector!(ctx.tmp_dir, endpoints)
      assert Buffer.take(buffer) == {:ok, batch}
      assert valid_batch?(buffer, batch)
    end

    test "the pollers and the uplink restart with the buffer; a failing uplink leaves the pollers",
         ctx do
      {_sim, port} = start_sim!(:tcp)
      {:ok, target} = Target.parse("http://127.0.0.1:1", "t.o.k", allow_http: true, cacerts: [])

      uplink = [
        target: target,
        clock: fn -> ~U[2026-11-01 00:00:00Z] end,
        idle_ms: 60_000,
        timeout_ms: 1_000,
        backoff_ms: %{min: 60_000, max: 60_000}
      ]

      {collector, _buffer} =
        start_collector!(ctx.tmp_dir, [endpoint(port, "tcp", [meter(1, "elite_440")])], uplink)

      first = children(collector)
      Process.exit(first[Alavi.Uplink], :kill)
      second = await_restart!(collector, [Alavi.Uplink], first)
      assert second[Alavi.Pollers] == first[Alavi.Pollers]
      assert second[Alavi.Buffer] == first[Alavi.Buffer]

      Process.exit(second[Alavi.Buffer], :kill)
      third = await_restart!(collector, [Alavi.Buffer, Alavi.Pollers, Alavi.Uplink], second)
      assert Map.keys(third) |> Enum.sort() == [Alavi.Buffer, Alavi.Pollers, Alavi.Uplink]
    end
  end

  defp children(collector),
    do: Map.new(Supervisor.which_children(collector), fn {id, pid, _, _} -> {id, pid} end)

  defp await_restart!(collector, ids, before, tries \\ 100) do
    now = children(collector)

    cond do
      Enum.all?(ids, &(is_pid(now[&1]) and now[&1] != before[&1])) -> now
      tries > 0 -> Process.sleep(10) && await_restart!(collector, ids, before, tries - 1)
      true -> flunk("#{inspect(ids)} never restarted")
    end
  end

  defp valid_batch?(buffer, batch) do
    schema =
      @contract |> Path.join("schema/batch.v1.schema.json") |> File.read!() |> JSON.decode!()

    wire = Wire.batch(batch, ~U[2026-11-01 00:05:00Z], Buffer.backlog(buffer))
    match?({:ok, _}, JSV.validate(wire, JSV.build!(schema, formats: true)))
  end

  describe "load/2" do
    setup %{tmp_dir: dir} do
      config = %{
        "schema_version" => 1,
        "endpoints" => [endpoint(5020, "tcp", [meter(1, "elite_440")])]
      }

      path = Path.join(dir, "polling.json")
      File.write!(path, JSON.encode!(config))

      json = %{
        "schema_version" => 1,
        "polling_config" => path,
        "profiles_dir" => Simulator.Profile.dir(),
        "buffer" => %{
          "dir" => Path.join(dir, "buffer"),
          "max_bytes" => 2_000_000_000,
          "max_batch_events" => 1000
        },
        "server" => %{"url" => "https://store.example/", "token" => "header.payload.signature"},
        "uplink" => %{
          "idle_ms" => 60_000,
          "timeout_ms" => 30_000,
          "backoff_ms" => %{"min" => 1000, "max" => 300_000}
        },
        "log" => %{
          "dir" => Path.join(dir, "log"),
          "max_file_bytes" => 1_000_000,
          "max_files" => 2
        },
        "raw_bytes_log" => %{"max_frame_bytes" => 64, "max_lines" => 10, "window_ms" => 60_000},
        "clock" => %{"refresh_ms" => 300_000}
      }

      {:ok, settings} = Settings.parse(json)
      {:ok, settings: settings}
    end

    test "loads the files the settings name", %{settings: settings} do
      assert {:ok, opts} = Collector.load(settings, @linux)
      assert [%{port: 5020}] = opts[:config].endpoints

      assert %{max_bytes: 2_000_000_000, max_batch_events: 1000, name: Buffer} =
               Map.new(opts[:buffer])
    end

    test "loads the uplink's settings, verifying the server against the OS's CAs",
         %{settings: settings} do
      assert {:ok, opts} = Collector.load(settings, @linux)
      uplink = Map.new(opts[:uplink])

      assert %{idle_ms: 60_000, timeout_ms: 30_000, backoff_ms: %{min: 1000, max: 300_000}} =
               uplink

      assert uplink.target.url == ~c"https://store.example/rpc/ingest"
      assert uplink.target.ssl[:verify] == :verify_peer
      assert uplink.target.ssl[:cacerts] == :public_key.cacerts_get()
    end

    test "off Windows the clock is unsynced, with nothing to watch it", %{settings: settings} do
      assert {:ok, opts} = Collector.load(settings, @linux)
      assert opts[:clock_status] == :none
      assert opts[:buffer][:clock_status] == (&Clock.unsynced/0)
    end

    test "on Windows the buffer reads the clock from a Windows Time watcher started first",
         %{settings: settings} do
      assert {:ok, opts} = Collector.load(settings, {:win32, :nt})
      watch = Map.new(opts[:clock_status])
      assert %{query: query, refresh_ms: 300_000, name: Clock.Windows} = watch
      assert query == (&Clock.Windows.w32tm/0)
      refute opts[:buffer][:clock_status] == (&Clock.unsynced/0)
    end

    test "refuses a plain http server URL", %{settings: settings} do
      settings = put_in(settings.server.url, "http://store.example/")

      assert {:error, "server URL http://store.example/: must be https://"} =
               Collector.load(settings, @linux)
    end

    test "refuses a token that is not a bearer token", %{settings: settings} do
      assert {:error, "server token: " <> _} =
               Collector.load(put_in(settings.server.token, "two words"), @linux)
    end

    test "names a polling config file that does not load", %{settings: settings} do
      assert {:error, message} =
               Collector.load(%{settings | polling_config: "/nonexistent.json"}, @linux)

      assert message =~ "/nonexistent.json"
    end
  end
end
