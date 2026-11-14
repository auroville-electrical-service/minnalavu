defmodule Alavi.UplinkTest do
  use ExUnit.Case, async: true

  import Alavi.PollerCase, only: [start_status!: 1, eventually!: 1, refused: 0]
  import ExUnit.CaptureLog

  alias Alavi.{Buffer, Clock, MissedRead, Reading, Status, TestServer, Uplink}
  alias Alavi.Uplink.Target

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
      backoff_ms: %{min: 10, max: 40},
      timeout_ms: 2_000,
      status: Alavi.NoStatus
    ]

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
        register_key: key,
        timestamp: ~U[2026-11-01 00:00:00.123456Z],
        raw_words: [18_417, 8192],
        value: Decimal.new("123456789012.000123456"),
        unit: "Wh"
      }
    end

    missed = %MissedRead{
      endpoint: %{host: "10.0.0.21", port: 502},
      unit_id: unit_id,
      meter_serial: "SIM-#{unit_id}",
      profile: "elite_440",
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
    Map.put(request, :json, JSON.decode!(request.body))
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
