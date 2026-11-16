defmodule Alavi.UplinkTest do
  use ExUnit.Case, async: true

  import Alavi.PollerCase,
    only: [
      start_status!: 1,
      eventually!: 1,
      refused: 0,
      endpoint: 4,
      document: 1,
      meter: 2,
      profiles: 0
    ]

  import ExUnit.CaptureLog

  alias Alavi.{
    Buffer,
    Clock,
    Config,
    ConfigKeeper,
    MissedRead,
    Reading,
    Status,
    TestServer,
    Uplink
  }

  alias Alavi.Config.Digest
  alias Alavi.Uplink.{HTTP, Response, Target}

  @moduletag :tmp_dir
  @moduletag :capture_log
  @contract Path.expand("../../../contract", __DIR__)
  @token "test.token.signature"

  setup %{tmp_dir: dir} do
    name = :"buffer_#{System.unique_integer([:positive])}"

    buffer = [
      dir: dir,
      max_bytes: 1_000_000,
      max_batch_events: 3,
      clock_status: &Clock.unsynced/0,
      name: name
    ]

    start_supervised!({Buffer, buffer})
    {:ok, buffer: name}
  end

  defp server!(answers), do: start_supervised!({TestServer, owner: self(), answers: answers})

  defp uplink!(buffer, port, opts \\ []) do
    {:ok, target} =
      Target.parse("http://127.0.0.1:#{port}", @token, allow_http: true, cacerts: [])

    base = [
      buffer: buffer,
      target: target,
      clock: fn -> ~U[2026-11-01 00:05:00Z] end,
      idle_ms: 20,
      heartbeat_ms: 60_000,
      intake: :none,
      config: :none,
      backoff_ms: %{min: 10, max: 40},
      timeout_ms: 2_000,
      status: Alavi.NoStatus
    ]

    # With a keeper, the heartbeat is its config's.
    base =
      if Keyword.get(opts, :config, :none) == :none,
        do: base,
        else: Keyword.delete(base, :heartbeat_ms)

    start_supervised!({Uplink, Keyword.merge(base, opts)})
  end

  defp record!(buffer, unit_id) do
    reading = fn key ->
      %Reading{
        endpoint: %{host: "10.0.0.21", port: 502},
        unit_id: unit_id,
        meter_serial: "SIM-#{unit_id}",
        product_code: "ELITE440-445",
        profile: "elite_440",
        profile_version: 1,
        register_key: key,
        timestamp: ~U[2026-11-01 00:00:00.123456Z],
        value: Decimal.new("123456789012.000123456")
      }
    end

    missed = %MissedRead{
      endpoint: %{host: "10.0.0.21", port: 502},
      unit_id: unit_id,
      meter_serial: "SIM-#{unit_id}",
      profile: "elite_440",
      profile_version: 1,
      register_key: "reactive_energy_import",
      timestamp: ~U[2026-11-01 00:00:01Z],
      reason: {:unreachable, {:socket, :econnrefused}},
      attempts: 0,
      raw_words: nil
    }

    :ok =
      Buffer.record(buffer, [
        reading.("active_energy_import"),
        reading.("active_energy_export"),
        missed
      ])
  end

  defp request! do
    assert_receive {:request, request}, 2_000
    Map.put(request, :json, request.body != "" && JSON.decode!(request.body))
  end

  # The next request carrying readings, past any heartbeats.
  defp batch_request! do
    case request!().json do
      %{"readings" => []} -> batch_request!()
      json -> json
    end
  end

  defp await_backlog!(buffer, pred, tries \\ 100) do
    backlog = Buffer.backlog(buffer)

    cond do
      pred.(backlog) -> backlog
      tries > 0 -> Process.sleep(20) && await_backlog!(buffer, pred, tries - 1)
      true -> flunk("backlog never matched: #{inspect(backlog)}")
    end
  end

  describe "start_link/1" do
    test "posts a batch in the batch schema's shape and deletes it once stored", ctx do
      record!(ctx.buffer, 1)
      server = server!([TestServer.stored()])
      uplink!(ctx.buffer, TestServer.port(server))

      request = request!()
      assert request.method == "POST" and request.path == "/rpc/ingest"
      assert request.headers["authorization"] == "Bearer " <> @token
      assert request.headers["content-type"] =~ "application/json"

      schema =
        @contract |> Path.join("schema/batch.v1.schema.json") |> File.read!() |> JSON.decode!()

      assert {:ok, _} = JSV.validate(request.json, JSV.build!(schema, formats: true))

      assert %{"readings" => [first | _], "missed_reads" => [missed]} = request.json
      assert first["value"] == "123456789012.000123456"
      assert first["timestamp"] == "2026-11-01T00:00:00.123456Z"
      assert %{"reason" => "unreachable", "detail" => "econnrefused"} = missed
      assert %{"events" => 3, "batches" => 1, "quarantined" => 0} = request.json["backlog"]
      refute Map.has_key?(request.json, "collector_id")

      await_backlog!(ctx.buffer, &(&1.batches == 0))
    end

    test "retries the same batch after 5xx and dropped connections until stored", ctx do
      record!(ctx.buffer, 1)

      server =
        server!([TestServer.status(503), :close, TestServer.status(502), TestServer.stored()])

      uplink!(ctx.buffer, TestServer.port(server))

      ids = for _ <- 1..4, do: request!().json["batch_id"]
      assert [_] = Enum.uniq(ids)
      await_backlog!(ctx.buffer, &(&1.batches == 0))
    end

    test "keeps retrying while the server cannot be reached", ctx do
      record!(ctx.buffer, 1)
      {:ok, listen} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, port} = :inet.port(listen)
      :ok = :gen_tcp.close(listen)

      log =
        capture_log(fn ->
          uplink!(ctx.buffer, port, timeout_ms: 50)
          Process.sleep(150)
        end)

      assert log =~ "not sent" and log =~ "#{refused()}"
      assert %{batches: 1, events: 3, quarantined: 0} = Buffer.backlog(ctx.buffer)
    end

    test "a 200 that is not the server's answer for the batch is not an acknowledgement", ctx do
      record!(ctx.buffer, 1)

      other = fn _ -> {200, ~s({"batch_id":"00000000-0000-4000-8000-000000000000"})} end
      portal = TestServer.status(200, "<html>Welcome to the network</html>")
      server = server!([portal, other, TestServer.stored()])
      uplink!(ctx.buffer, TestServer.port(server))

      ids = for _ <- 1..3, do: request!().json["batch_id"]
      assert [_] = Enum.uniq(ids)
      await_backlog!(ctx.buffer, &(&1.batches == 0))
    end

    test "a batch rejected for good is quarantined, loudly, and the next one sent", ctx do
      record!(ctx.buffer, 1)
      record!(ctx.buffer, 2)
      rejected = ~s({"code":"PT422","message":"batch rejected: batch.readings[0].value must be"})
      server = server!([TestServer.status(422, rejected), TestServer.stored()])

      log =
        capture_log(fn ->
          uplink!(ctx.buffer, TestServer.port(server))
          first = request!().json["batch_id"]
          second = request!().json["batch_id"]
          assert first != second
          await_backlog!(ctx.buffer, &(&1.batches == 0))
        end)

      assert log =~ "[error]" and log =~ "quarantined" and log =~ "PT422"
      assert %{quarantined: 1, events: 0} = Buffer.backlog(ctx.buffer)
      reason = ctx.tmp_dir |> Path.join("quarantine/*.reason") |> Path.wildcard()
      assert [file] = reason
      assert File.read!(file) =~ "HTTP 422 PT422: batch rejected"
    end

    test "409, 400 and 413 are permanent too", ctx do
      for unit <- 1..3, do: record!(ctx.buffer, unit)

      server =
        server!([
          TestServer.status(409, ~s({"code":"PT409","message":"another collector"})),
          TestServer.status(400, ~s({"code":"PGRST102","message":"Empty or invalid json"})),
          TestServer.status(413, "too large")
        ])

      uplink!(ctx.buffer, TestServer.port(server))
      ids = for _ <- 1..3, do: request!().json["batch_id"]
      assert length(Enum.uniq(ids)) == 3
      assert %{quarantined: 3} = await_backlog!(ctx.buffer, &(&1.quarantined == 3))
    end

    test "auth failures, and errors that are not the server's, are retried, not quarantined",
         ctx do
      record!(ctx.buffer, 1)

      server =
        server!([
          TestServer.status(401, ~s({"code":"PGRST303","message":"JWT expired"})),
          TestServer.status(403, ~s({"code":"42501","message":"permission denied"})),
          TestServer.status(422, "<html>proxy</html>"),
          TestServer.status(404, ""),
          TestServer.stored()
        ])

      uplink!(ctx.buffer, TestServer.port(server))
      ids = for _ <- 1..5, do: request!().json["batch_id"]
      assert [_] = Enum.uniq(ids)
      assert %{quarantined: 0} = await_backlog!(ctx.buffer, &(&1.batches == 0))
    end

    test "each attempt, its result and the next attempt reach the status", ctx do
      record!(ctx.buffer, 1)
      status = start_status!(ctx.tmp_dir)
      server = server!([TestServer.status(503), TestServer.stored()])

      uplink!(ctx.buffer, TestServer.port(server),
        status: status,
        backoff_ms: %{min: 300, max: 300}
      )

      :ok = eventually!(fn -> match?(%{result: "not_sent"}, Status.read(status).uplink) end)
      assert Status.read(status).uplink.detail =~ "HTTP 503"

      :ok =
        eventually!(fn ->
          match?(%{result: "empty", batch_id: nil}, Status.read(status).uplink)
        end)
    end

    test "an empty buffer is looked at again after idle_ms", ctx do
      server = server!([TestServer.stored()])
      uplink!(ctx.buffer, TestServer.port(server))
      refute_receive {:request, _}, 100

      record!(ctx.buffer, 1)
      assert request!().json["readings"] != []
    end
  end

  describe "start_link/1, with nothing to send" do
    defp valid!(json) do
      schema =
        @contract |> Path.join("schema/batch.v1.schema.json") |> File.read!() |> JSON.decode!()

      assert {:ok, _} = JSV.validate(json, JSV.build!(schema, formats: true))
    end

    test "with nothing to send for heartbeat_ms, an empty batch in the schema's shape", ctx do
      server = server!([TestServer.stored()])
      uplink!(ctx.buffer, TestServer.port(server), heartbeat_ms: 150)
      refute_receive {:request, _}, 100

      first = request!().json
      valid!(first)

      assert %{"readings" => [], "missed_reads" => [], "clock" => %{"source" => "unsynced"}} =
               first

      assert first["backlog"]["events"] == 0

      # The next only once heartbeat_ms has passed again, under a new id.
      refute_receive {:request, _}, 100
      assert request!().json["batch_id"] != first["batch_id"]
      assert %{batches: 0, events: 0} = Buffer.backlog(ctx.buffer)
    end

    test "an answer to a batch puts the heartbeat off", ctx do
      server = server!([TestServer.stored()])
      record!(ctx.buffer, 1)
      uplink!(ctx.buffer, TestServer.port(server), heartbeat_ms: 300)

      assert request!().json["readings"] != []
      refute_receive {:request, _}, 200
      assert request!().json["readings"] == []
    end

    test "a heartbeat that is not stored is sent again, as a new one, after the backoff", ctx do
      server = server!([TestServer.status(503), TestServer.stored()])

      log =
        capture_log(fn ->
          uplink!(ctx.buffer, TestServer.port(server),
            heartbeat_ms: 1,
            backoff_ms: %{min: 100, max: 100}
          )

          first = request!().json["batch_id"]
          refute_receive {:request, _}, 50
          assert request!().json["batch_id"] != first
        end)

      assert log =~ "heartbeat" and log =~ "HTTP 503"
      assert %{batches: 0, quarantined: 0} = Buffer.backlog(ctx.buffer)
    end

    test "a heartbeat stored after failures resets the backoff for the next batch", ctx do
      # Counted apart: three heartbeats fail, then are stored; a batch fails once.
      sent = :counters.new(2, [])
      failures = %{1 => 3, 2 => 1}

      answer = fn %{body: body} = request ->
        slot = if JSON.decode!(body)["readings"] == [], do: 1, else: 2
        :counters.add(sent, slot, 1)

        if :counters.get(sent, slot) <= failures[slot],
          do: {503, ""},
          else: TestServer.stored().(request)
      end

      server = server!([answer])

      uplink!(ctx.buffer, TestServer.port(server),
        heartbeat_ms: 1,
        backoff_ms: %{min: 50, max: 1_000}
      )

      # Waits of 50, 100 and 200 ms after the failures leave the next at 400.
      for _ <- 1..4, do: assert(request!().json["readings"] == [])
      record!(ctx.buffer, 1)
      first = batch_request!()
      at = System.monotonic_time(:millisecond)
      assert batch_request!()["batch_id"] == first["batch_id"]
      assert System.monotonic_time(:millisecond) - at < 300
    end

    test "jobs and unknown requests in an answer are logged when there is no intake", ctx do
      answer = fn %{body: body} ->
        {200,
         JSON.encode!(%{
           "batch_id" => JSON.decode!(body)["batch_id"],
           "readings" => %{},
           "missed_reads" => %{},
           "jobs" => [%{"request_id" => "7d2c1f0e-4b3a-4c5d-8e6f-1a2b3c4d5e6f"}],
           "unknown_requests" => ["0b6f8d2e-5c1a-4e7b-9a3d-2f4c6e8a0b1c"]
         })}
      end

      record!(ctx.buffer, 1)
      server = server!([answer, TestServer.stored()])

      log =
        capture_log(fn ->
          uplink!(ctx.buffer, TestServer.port(server))
          await_backlog!(ctx.buffer, &(&1.batches == 0))
        end)

      assert log =~ "no intake to run them" and log =~ "7d2c1f0e"
      assert log =~ "does not know" and log =~ "0b6f8d2e"
    end
  end

  describe "start_link/1, with a config keeper" do
    # Ingest answers name `served`'s digest; GET /rpc/collector_config serves it.
    defp serving(served) do
      fn
        %{method: "GET"} ->
          {200, JSON.encode!(served)}

        %{body: body} ->
          {:ok, digest} = Digest.digest(served)
          id = JSON.decode!(body)["batch_id"]
          {200, JSON.encode!(%{"batch_id" => id, "config_digest" => digest})}
      end
    end

    # Its config's meter is polled every `interval_ms`, so the heartbeat is due as often.
    defp keeper!(dir, port, interval_ms \\ 50) do
      {:ok, target} =
        Target.parse("http://127.0.0.1:#{port}", @token, allow_http: true, cacerts: [])

      start =
        document([
          endpoint(5020, "tcp", [meter(1, "elite_440")], %{"interval_ms" => interval_ms})
        ])

      {:ok, config} = Config.parse(start, profiles())
      {:ok, digest} = Digest.digest(start)
      name = :"keeper_#{System.unique_integer([:positive])}"

      start_supervised!(
        {ConfigKeeper,
         config: config,
         digest: digest,
         profiles: profiles(),
         dir: dir,
         fetch: fn -> target |> HTTP.get_config(2_000) |> Response.config() end,
         status: Alavi.NoStatus,
         name: name}
      )

      {name, digest}
    end

    defp posts!(n), do: for(_ <- 1..n, do: post!())

    # The next POST, counting the GETs before it.
    defp post!(gets \\ 0) do
      case request!() do
        %{method: "GET"} -> post!(gets + 1)
        %{json: json} -> {json, gets}
      end
    end

    test "a new digest in an answer is fetched with the token, and the next backlog reports it",
         ctx do
      served = document([endpoint(5021, "tcp", [meter(1, "elite_440")], %{"interval_ms" => 50})])

      {:ok, new} = Digest.digest(served)
      server = server!([serving(served)])
      {keeper, start} = keeper!(ctx.tmp_dir, TestServer.port(server))
      uplink!(ctx.buffer, TestServer.port(server), config: keeper)

      {first, 0} = post!()

      assert first["backlog"]["config"] == %{
               "digest" => start,
               "refused_digest" => nil,
               "reason" => nil
             }

      assert_receive {:request,
                      %{method: "GET", path: "/rpc/collector_config", headers: headers}},
                     2_000

      assert headers["authorization"] == "Bearer " <> @token
      {second, 0} = post!()
      assert second["backlog"]["config"]["digest"] == new
      assert [{_, 0}, {_, 0}] = posts!(2)
    end

    test "a config applied sets the heartbeat interval, and with it a heartbeat is its config's",
         ctx do
      served = document([endpoint(5021, "tcp", [meter(1, "elite_440")], %{"interval_ms" => 50})])

      server = server!([serving(served)])
      {keeper, _start} = keeper!(ctx.tmp_dir, TestServer.port(server), 60_000)

      assert_raise RuntimeError, ~r/the heartbeat follows its config/, fn ->
        uplink!(ctx.buffer, TestServer.port(server), config: keeper, heartbeat_ms: 50)
      end

      uplink!(ctx.buffer, TestServer.port(server), config: keeper)
      refute_receive {:request, _}, 200
      record!(ctx.buffer, 1)
      {_batch, 0} = post!()
      assert [{_, 1}, {_, 0}] = posts!(2)
    end

    test "a refused config is reported in each backlog and not fetched again", ctx do
      served = document([])
      {:ok, refused} = Digest.digest(served)
      server = server!([serving(served)])
      {keeper, start} = keeper!(ctx.tmp_dir, TestServer.port(server))
      uplink!(ctx.buffer, TestServer.port(server), config: keeper)

      [{_, 0}, {_, 1} | rest] = posts!(5)
      assert Enum.all?(rest, &match?({_, 0}, &1))

      for {json, _} <- rest do
        assert %{"digest" => ^start, "refused_digest" => ^refused, "reason" => "endpoints" <> _} =
                 json["backlog"]["config"]

        valid!(json)
      end
    end

    test "an answer whose digest is not a SHA-256 in lowercase hex fetches nothing", ctx do
      answer = fn %{body: body} ->
        id = JSON.decode!(body)["batch_id"]
        {200, JSON.encode!(%{"batch_id" => id, "config_digest" => String.duplicate("A", 64)})}
      end

      server = server!([answer])
      {keeper, _start} = keeper!(ctx.tmp_dir, TestServer.port(server))

      log =
        capture_log(fn ->
          uplink!(ctx.buffer, TestServer.port(server), config: keeper)
          assert [{_, 0}, {_, 0}, {_, 0}] = posts!(3)
        end)

      assert log =~ "config_digest is not a SHA-256"
    end
  end

  describe "nudge/1" do
    test "an idle uplink sends what was recorded at once, not after its idle wait", ctx do
      server = server!([TestServer.stored()])
      uplink = uplink!(ctx.buffer, TestServer.port(server), idle_ms: 60_000)
      :ok = eventually!(fn -> Buffer.backlog(ctx.buffer).batches == 0 end)
      refute_receive {:request, _}, 100

      record!(ctx.buffer, 1)
      Uplink.nudge(uplink)
      assert %{json: %{"readings" => [_, _]}} = request!()
      await_backlog!(ctx.buffer, &(&1.batches == 0))

      # The idle wait it replaced sends nothing more.
      Uplink.nudge(uplink)
      refute_receive {:request, _}, 200
    end

    test "a nudge after a heartbeat sends what was recorded at once", ctx do
      server = server!([TestServer.stored()])
      uplink = uplink!(ctx.buffer, TestServer.port(server), idle_ms: 60_000, heartbeat_ms: 1)
      assert request!().json["readings"] == []
      refute_receive {:request, _}, 100

      record!(ctx.buffer, 1)
      Uplink.nudge(uplink)
      assert %{json: %{"readings" => [_, _]}} = request!()
    end

    test "an uplink backing off after a failed send waits out its backoff", ctx do
      record!(ctx.buffer, 1)
      server = server!([TestServer.status(503)])

      uplink =
        uplink!(ctx.buffer, TestServer.port(server), backoff_ms: %{min: 60_000, max: 60_000})

      assert %{json: %{"readings" => [_, _]}} = request!()

      Uplink.nudge(uplink)
      refute_receive {:request, _}, 200
    end
  end
end
