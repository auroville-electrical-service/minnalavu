defmodule Alavi.UplinkTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Alavi.{Buffer, Clock, MissedRead, Reading, TestServer, Uplink}
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
      backoff_ms: %{min: 10, max: 40},
      timeout_ms: 2_000
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
          uplink!(ctx.buffer, port)
          Process.sleep(150)
        end)

      assert log =~ "not sent" and log =~ "econnrefused"
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

    test "an empty buffer is looked at again after idle_ms", ctx do
      server = server!([TestServer.stored()])
      uplink!(ctx.buffer, TestServer.port(server))
      refute_receive {:request, _}, 100

      record!(ctx.buffer, 1)
      assert request!().json["readings"] != []
    end
  end
end
