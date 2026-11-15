defmodule Alavi.CollectorTest do
  use ExUnit.Case, async: true

  import Alavi.PollerCase

  alias Alavi.{
    Buffer,
    Clock,
    Collector,
    FirmwareRead,
    MissedRead,
    Reading,
    Settings,
    TestServer,
    Wire
  }

  alias Alavi.Buffer.Batch
  alias Alavi.Uplink.Target

  @moduletag :tmp_dir
  @moduletag :capture_log
  @contract Path.expand("../../../contract", __DIR__)
  @linux {:unix, :linux}

  defp start_collector!(
         dir,
         endpoints,
         uplink \\ :none,
         status \\ no_status(),
         clock \\ fixed_clock(),
         named \\ []
       ) do
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
      clock: clock,
      uplink: uplink,
      raw_log: raw_log(),
      clock_status: :none,
      status: status
    ]

    {start_supervised!({Collector, opts ++ named}, id: :collector), name}
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
      :ok = await_events!(buffer, 10)
      {:ok, %Batch{events: events} = batch} = Buffer.take(buffer)

      assert Enum.map(events, & &1.unit_id) |> Enum.dedup() == [1, 9, 3, 1, 3]

      %{Reading => readings, MissedRead => missed, FirmwareRead => names} =
        Enum.group_by(events, & &1.__struct__)

      assert length(readings) == 6
      assert Enum.all?(missed, &match?(%MissedRead{unit_id: 9}, &1))
      assert hd(readings).value == Decimal.new("123456")
      assert [%{unit_id: 1, software: "SIM-SW"}, %{unit_id: 3, software: "SIM-SW"}] = names

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

    # Per meter, a round's missed reads: one per register.
    @round %{1 => 2, 3 => 4}
    @outage %{
      "interval_ms" => 50,
      "timeout_ms" => 50,
      "reconnect_backoff_ms" => %{"min" => 10, "max" => 100}
    }
    # Back online, a poller finishes the connect in flight, waits out its
    # backoff, at its max by then, and connects: within an interval of that.
    @back_ms 50 + 100 + 50

    test "every endpoint unreachable at once: each meter is missed, then read again soon after, " <>
           "with nothing restarted, past an endpoint that refuses throughout",
         ctx do
      sims = for _ <- 1..3, do: start_sim!(:tcp)
      refusing = refusing_port!()
      live = for {_sim, port} <- sims, unit <- [1, 3], do: {port, unit}
      endpoints = [{nil, refusing} | sims] |> Enum.with_index() |> Enum.map(&outage_endpoint/1)
      server = start_supervised!({TestServer, owner: self(), answers: [TestServer.stored()]})
      uplink = uplink_to(TestServer.port(server))

      {collector, _buffer} =
        start_collector!(ctx.tmp_dir, endpoints, uplink, no_status(), &DateTime.utc_now/0)

      posted = posted!([], &each?(&1, live, fn e -> e.kind == :reading end))
      tree = tree(collector)

      Enum.each(sims, &Simulator.offline(elem(&1, 0)))
      off = DateTime.utc_now()
      # Five rounds take the backoff to its max; eight leave an uncapped one far past it.
      posted = posted!(posted, &(rounds_unreachable(&1, live, off) >= 8))

      on = DateTime.utc_now()
      Enum.each(sims, &Simulator.online(elem(&1, 0)))
      posted = posted!(posted, &each?(&1, live, fn e -> e.kind == :reading and after?(e, on) end))

      assert tree(collector) == tree
      {refused, seen} = Enum.split_with(posted, &(elem(key(&1), 0) == refusing))

      for e <- seen, after?(e, off) and not after?(e, on) do
        assert e.kind == :missed and (e.wire["reason"] == "timeout" or connect_timeout?(e))
      end

      for {{_port, unit}, events} <- Enum.group_by(seen, &key/1) do
        for kind <- [:reading, :missed], as_posted = Enum.filter(events, &(&1.kind == kind)) do
          assert Enum.sort_by(as_posted, & &1.at, DateTime) == as_posted
        end

        events = Enum.sort_by(events, & &1.at, DateTime)
        assert events |> Enum.map(& &1.kind) |> Enum.dedup() == [:reading, :missed, :reading]

        {missed, [back | _]} =
          events |> Enum.filter(&after?(&1, on)) |> Enum.split_while(&(&1.kind == :missed))

        assert length(missed) <= @round[unit]
        assert DateTime.diff(back.at, on, :millisecond) < @back_ms + 200
      end

      assert refused != [] and
               Enum.all?(refused, &(&1.kind == :missed and &1.wire["detail"] == "#{refused()}"))
    end

    test "the heartbeat follows the shortest interval polled here, not another system's", ctx do
      {_sim, port} = start_sim!(:tcp)
      other = refusing_port!()

      endpoints = [
        endpoint(port, "tcp", [meter(1, "elite_440")]),
        endpoint(other, "tcp", [meter(1, "elite_440", %{"serial" => "OTHER-1"})], %{
          "polled_by_other_system" => true,
          "interval_ms" => 100
        })
      ]

      server = start_supervised!({TestServer, owner: self(), answers: [TestServer.stored()]})
      start_collector!(ctx.tmp_dir, endpoints, uplink_to(TestServer.port(server)))

      assert_receive {:request, _first}, 2_000
      Process.sleep(600)
      refute Enum.any?(bodies_now(), &heartbeat?/1)
    end

    test "with no meter polled here, the heartbeat is due after the uplink's idle_ms", ctx do
      other = refusing_port!()

      endpoints = [
        endpoint(other, "tcp", [meter(1, "elite_440", %{"serial" => "OTHER-1"})], %{
          "polled_by_other_system" => true
        })
      ]

      server = start_supervised!({TestServer, owner: self(), answers: [TestServer.stored()]})
      start_collector!(ctx.tmp_dir, endpoints, uplink_to(TestServer.port(server)))

      assert_receive {:request, %{body: first}}, 1_000
      assert_receive {:request, %{body: second}}, 1_000
      assert heartbeat?(JSON.decode!(first)) and heartbeat?(JSON.decode!(second))
    end
  end

  # Units 1 and 3, under serials unique to the endpoint, set on its simulator if it has one.
  defp outage_endpoint({{sim, port}, n}) do
    meters =
      for {unit, profile} <- [{1, "elite_440"}, {3, "elite_500"}] do
        serial = "SIM-#{n}-#{unit}"
        if sim, do: :ok = Simulator.identify(sim, unit, :serial, serial)
        meter(unit, profile, %{"serial" => serial})
      end

    endpoint(port, "tcp", meters, @outage)
  end

  # The fewest rounds any of `keys` has been missed as unreachable since `since`.
  defp rounds_unreachable(events, keys, since) do
    counts =
      events
      |> Enum.filter(&(after?(&1, since) and connect_timeout?(&1)))
      |> Enum.frequencies_by(&key/1)

    keys
    |> Enum.map(fn {_port, unit} = k -> div(Map.get(counts, k, 0), @round[unit]) end)
    |> Enum.min()
  end

  describe "start_link/1, with its pollers named" do
    test "a read on demand reaches them by name", ctx do
      {_sim, port} = start_sim!(:tcp)
      endpoints = [endpoint(port, "tcp", [meter(1, "elite_440")])]
      pollers = :"pollers_#{System.unique_integer([:positive])}"

      {collector, _buffer} =
        start_collector!(ctx.tmp_dir, endpoints, :none, no_status(), fixed_clock(),
          pollers: pollers
        )

      assert children(collector)[Alavi.Pollers] == Process.whereis(pollers)
      assert {:ok, ref} = Alavi.Pollers.read_now(pollers, {"127.0.0.1", port}, [1])
      assert_receive {:alavi_read, ^ref, [%Reading{unit_id: 1} | _]}, 2_000
    end

    test "a job the server lists is read once, and its readings sent at once, tagged", ctx do
      {_sim, port} = start_sim!(:tcp)
      endpoints = [endpoint(port, "tcp", [meter(1, "elite_440"), meter(3, "elite_500")])]
      pollers = :"pollers_#{System.unique_integer([:positive])}"
      id = "7d2c1f0e-4b3a-4c5d-8e6f-1a2b3c4d5e6f"

      job = %{
        "request_id" => id,
        "kind" => "read_on_demand",
        "meters" => ["SIM-3"],
        "requested_at" => "2026-11-01T00:00:00Z",
        "expires_at" => DateTime.utc_now() |> DateTime.add(3_600) |> DateTime.to_iso8601()
      }

      # As the server does, the job is listed in every answer.
      answer = fn %{body: body} ->
        {200, JSON.encode!(%{"batch_id" => JSON.decode!(body)["batch_id"], "jobs" => [job]})}
      end

      server = start_supervised!({TestServer, owner: self(), answers: [answer]})
      uplink = uplink_to(TestServer.port(server)) ++ [name: :"uplink_#{pollers}"]

      start_collector!(ctx.tmp_dir, endpoints, uplink, no_status(), &DateTime.utc_now/0,
        pollers: pollers
      )

      tagged =
        posted!([], fn events -> Enum.count(events, &(&1.wire["request_id"] == id)) >= 4 end)
        |> Enum.filter(&(&1.wire["request_id"] == id))

      assert Enum.all?(tagged, &(key(&1) == {port, 3} and &1.kind == :reading))

      # Listed again in every answer, it is not read again.
      Process.sleep(300)
      later = posted_now()
      refute Enum.any?(later, &(&1.wire["request_id"] == id))
    end
  end

  describe "start_link/1, fed to a status" do
    test "the pollers feed the status, and its crash leaves the collector be", ctx do
      {_sim, port} = start_sim!(:tcp)
      endpoints = [endpoint(port, "tcp", [meter(1, "elite_440")])]
      name = :"status_#{System.unique_integer([:positive])}"

      status = [
        config: config!(endpoints),
        settings: [],
        version: "0.1.0",
        buffer: :no_such_buffer,
        file: Path.join(ctx.tmp_dir, "status.json"),
        clock: &DateTime.utc_now/0,
        tick_ms: 60_000,
        name: name
      ]

      status_pid = start_supervised!({Alavi.Status, status}, id: :status)
      {collector, _buffer} = start_collector!(ctx.tmp_dir, endpoints, :none, name)
      :ok = await_serial!(name, "SIM-1")

      before = children(collector)
      Process.exit(status_pid, :kill)
      Process.sleep(50)
      assert children(collector) == before
    end
  end

  defp fixed_clock, do: fn -> ~U[2026-11-01 00:00:00Z] end

  defp uplink_to(port) do
    {:ok, target} =
      Target.parse("http://127.0.0.1:#{port}", "t.o.k", allow_http: true, cacerts: [])

    [
      target: target,
      clock: &DateTime.utc_now/0,
      idle_ms: 20,
      timeout_ms: 1_000,
      backoff_ms: %{min: 10, max: 40}
    ]
  end

  # The readings and missed reads posted so far, in the order posted, until `done?` holds.
  defp posted!(events, done?, tries \\ 500) do
    cond do
      done?.(events) ->
        events

      tries > 0 ->
        assert_receive {:request, %{body: body}}, 2_000
        posted!(events ++ events(JSON.decode!(body)), done?, tries - 1)

      true ->
        flunk("the posted events never matched")
    end
  end

  # The readings and missed reads of every request already received.
  defp posted_now do
    receive do
      {:request, %{body: body}} -> events(JSON.decode!(body)) ++ posted_now()
    after
      0 -> []
    end
  end

  defp bodies_now do
    receive do
      {:request, %{body: body}} -> [JSON.decode!(body) | bodies_now()]
    after
      0 -> []
    end
  end

  defp heartbeat?(batch),
    do: batch["readings"] == [] and batch["missed_reads"] == [] and batch["firmware_reads"] == nil

  defp events(batch) do
    for {kind, field} <- [reading: "readings", missed: "missed_reads"], wire <- batch[field] do
      {:ok, at, 0} = DateTime.from_iso8601(wire["timestamp"])
      %{kind: kind, at: at, wire: wire}
    end
  end

  defp key(%{wire: wire}), do: {wire["endpoint"]["port"], wire["unit_id"]}

  defp each?(events, keys, pred),
    do: Enum.all?(keys, fn k -> Enum.any?(events, &(key(&1) == k and pred.(&1))) end)

  defp after?(event, at), do: DateTime.compare(event.at, at) != :lt

  defp connect_timeout?(%{wire: wire}),
    do: wire["reason"] == "unreachable" and wire["detail"] == "timeout"

  # The collector's children and the pollers under them.
  defp tree(collector) do
    top = children(collector)
    Map.merge(top, children(top[Alavi.Pollers]))
  end

  defp await_serial!(status, serial, tries \\ 100) do
    [meter] = hd(Alavi.Status.read(status).endpoints).meters

    cond do
      meter.serial == serial -> :ok
      tries > 0 -> Process.sleep(20) && await_serial!(status, serial, tries - 1)
      true -> flunk("the status never showed serial #{serial}")
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
        "schema_version" => 2,
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
        "clock" => %{"refresh_ms" => 300_000},
        "status" => %{"port" => 8502}
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

    test "names the pollers, for a read on demand to reach", %{settings: settings} do
      assert {:ok, opts} = Collector.load(settings, @linux)
      assert opts[:pollers] == Alavi.Pollers
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
