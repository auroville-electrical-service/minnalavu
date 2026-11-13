defmodule Alavi.Modbus.ClientTest do
  use ExUnit.Case, async: true

  alias Alavi.Modbus.Client
  alias Alavi.{Profile, Reader}
  alias Simulator.Meter

  @timeout 200
  @max_timeouts 3
  @profiles Simulator.Profile.dir()

  describe "read/5" do
    for framing <- [:tcp, :rtu_over_tcp] do
      test "#{framing}: reads every meter on a daisy chain behind one endpoint" do
        ctx = start_chain(unquote(framing))
        {:ok, client} = connect(ctx)

        client =
          Enum.reduce(
            [
              {1, "elite_440", "123456.000"},
              {2, "elite_440", "7.500"},
              {3, "elite_500", "1234.500"}
            ],
            client,
            fn {unit, name, expected}, client ->
              {:ok, register} = Profile.register(ctx.profiles[name], "active_energy_import")
              assert {:ok, %{value: value}, client} = Reader.read(client, unit, register)
              assert Decimal.to_string(value) == expected
              client
            end
          )

        Client.close(client)
      end

      test "#{framing}: an unmapped address is a Modbus exception and keeps the connection" do
        ctx = start_chain(unquote(framing))
        {:ok, client} = connect(ctx)
        assert {:error, {:exception, 2}, client} = Client.read(client, 1, :input, 0, 2)
        assert {:ok, [_, _], _client} = Client.read(client, 1, :holding, 199, 2)
      end

      test "#{framing}: a missing meter behind a gateway is exception 0B and keeps the connection" do
        ctx = start_chain(unquote(framing), missing_units: :gateway_error)
        {:ok, client} = connect(ctx)
        assert {:error, {:exception, 0x0B}, client} = Client.read(client, 9, :holding, 199, 2)
        assert {:ok, [_, _], _client} = Client.read(client, 1, :holding, 199, 2)
      end

      test "#{framing}: many reads on one connection stay matched to their requests" do
        ctx = start_chain(unquote(framing))
        {:ok, register} = Profile.register(ctx.profiles["elite_440"], "active_energy_import")
        expected = %{1 => "123456.000", 2 => "7.500"}

        Enum.reduce(1..50, client!(ctx), fn i, client ->
          unit = rem(i, 2) + 1
          assert {:ok, %{value: value}, client} = Reader.read(client, unit, register)
          assert Decimal.to_string(value) == expected[unit]
          client
        end)
      end

      test "#{framing}: a busy endpoint answers exception 06" do
        ctx = start_chain(unquote(framing))
        Simulator.faults(ctx.sim, busy: true)
        {:ok, client} = connect(ctx)
        assert {:error, {:exception, 6}, _} = Client.read(client, 1, :holding, 199, 2)
      end

      test "#{framing}: a slow response past the timeout is a timeout" do
        ctx = start_chain(unquote(framing))
        Simulator.faults(ctx.sim, delay_ms: @timeout * 2)
        {:ok, client} = connect(ctx)
        assert {:error, :timeout, _} = Client.read(client, 1, :holding, 199, 2)
      end

      test "#{framing}: a second connection to a one-connection endpoint is refused" do
        ctx = start_chain(unquote(framing))
        {:ok, first} = connect(ctx)
        {:ok, second} = connect(ctx)
        assert {:error, reason, _} = Client.read(second, 1, :holding, 199, 2)
        assert reason in [:closed, {:socket, :econnreset}]
        assert {:ok, _, _} = Client.read(first, 1, :holding, 199, 2)
      end

      test "#{framing}: a meter configured with the other word order reads differently" do
        ctx = start_chain(unquote(framing))
        {:ok, client} = connect(ctx)
        {:ok, register} = Profile.register(ctx.profiles["elite_500"], "active_energy_import")
        assert {:ok, %{value: value}, _} = Reader.read(client, 4, register)
        refute Decimal.to_string(value) == "1234.500"
      end
    end

    test "tcp: a missing meter times out and the next meter reads on the same connection" do
      {:ok, client} = connect(start_chain(:tcp))

      assert {:error, :timeout, %Client{socket: socket} = client} =
               Client.read(client, 9, :holding, 199, 2)

      assert socket != nil
      assert {:ok, [_, _], _} = Client.read(client, 1, :holding, 199, 2)
    end

    test "tcp: closes after max_timeouts timeouts in a row, and an answer resets the count" do
      {:ok, client} = connect(start_chain(:tcp))
      missing = fn client -> Client.read(client, 9, :holding, 199, 2) end

      assert {:error, :timeout, client} = missing.(client)
      assert {:error, :timeout, client} = missing.(client)
      assert {:ok, _, client} = Client.read(client, 1, :holding, 199, 2)
      assert {:error, :timeout, client} = missing.(client)
      assert {:error, :timeout, %Client{socket: socket} = client} = missing.(client)
      assert socket != nil
      assert {:error, :timeout, %Client{socket: nil}} = missing.(client)
    end

    test "tcp: a late reply to a timed-out request is skipped" do
      ctx = start_chain(:tcp)
      {:ok, register} = Profile.register(ctx.profiles["elite_440"], "active_energy_import")
      Simulator.faults(ctx.sim, delay_ms: div(@timeout * 3, 2))
      {:ok, client} = connect(ctx)
      assert {:error, :timeout, client} = Reader.read(client, 1, register)

      # The reply to unit 1 arrives during this read, ahead of unit 2's.
      Simulator.clear_faults(ctx.sim)
      assert {:ok, %{value: value}, _} = Reader.read(client, 2, register)
      assert Decimal.to_string(value) == "7.500"
    end

    test "rtu_over_tcp: a missing meter times out and closes the connection" do
      {:ok, client} = connect(start_chain(:rtu_over_tcp))
      assert {:error, :timeout, %Client{socket: nil}} = Client.read(client, 9, :holding, 199, 2)
    end

    test "rtu_over_tcp: a silent meter does not block the others after reconnecting" do
      ctx = start_chain(:rtu_over_tcp)
      Simulator.faults(ctx.sim, silent_units: [2])
      {:ok, client} = connect(ctx)
      assert {:error, :timeout, closed} = Client.read(client, 2, :holding, 199, 2)
      assert {:error, :closed, _} = Client.read(closed, 1, :holding, 199, 2)

      assert {:ok, _, _} = reconnect_and_read(ctx, 1, 10)
    end

    test "rtu_over_tcp: noise before each reply is skipped, even noise that starts like one" do
      ctx = start_chain(:rtu_over_tcp)
      {:ok, register} = Profile.register(ctx.profiles["elite_440"], "active_energy_import")
      expected = %{1 => "123456.000", 2 => "7.500"}
      # <<1, 4>> is how unit 1's reply to a function 04 read begins.
      Simulator.faults(ctx.sim, noise: <<0xFF, 1, 4>>)

      Enum.reduce(1..10, client!(ctx), fn i, client ->
        unit = rem(i, 2) + 1
        assert {:ok, %{value: value}, client} = Reader.read(client, unit, register)
        assert Decimal.to_string(value) == expected[unit]
        client
      end)
    end

    test "rtu_over_tcp: a corrupted CRC is rejected and closes the connection" do
      ctx = start_chain(:rtu_over_tcp)
      Simulator.faults(ctx.sim, bad_crc: true)
      {:ok, client} = connect(ctx)
      assert {:error, :bad_crc, %Client{socket: nil}} = Client.read(client, 1, :holding, 199, 2)
    end

    test "a read on a closed client returns :closed" do
      ctx = start_chain(:tcp)
      client = ctx |> connect() |> elem(1) |> Client.close()
      assert {:error, :closed, ^client} = Client.read(client, 1, :holding, 199, 2)
    end
  end

  describe "take_anomalies/1" do
    test "rtu_over_tcp: noise skipped before a reply is kept as data, for the caller" do
      ctx = start_chain(:rtu_over_tcp)
      Simulator.faults(ctx.sim, noise: <<0xFF, 0xFE>>)
      {:ok, client} = connect(ctx)

      assert {:ok, [_, _], client} = Client.read(client, 1, :holding, 199, 2)

      assert {[%{kind: :skipped, unit_id: 1, reasons: [:noise], bytes: <<0xFF, 0xFE>>}], client} =
               Client.take_anomalies(client)

      assert {[], _} = Client.take_anomalies(client)
    end

    test "rtu_over_tcp: a frame with a bad CRC is kept whole, with what came before it" do
      ctx = start_chain(:rtu_over_tcp)
      Simulator.faults(ctx.sim, bad_crc: true, noise: <<0xAA>>)
      {:ok, client} = connect(ctx)

      assert {:error, :bad_crc, client} = Client.read(client, 1, :holding, 199, 2)

      assert {[%{kind: :skipped, reasons: reasons, bytes: bytes}], _} =
               Client.take_anomalies(client)

      assert :bad_crc in reasons and :noise in reasons
      # noise, then unit 1, function 04, 4 data bytes, and the corrupted CRC
      assert <<0xAA, 1, 3, 4, _::binary-size(4), _crc::16>> = bytes
    end

    test "tcp: a late reply skipped as stale is kept, under the unit being read" do
      ctx = start_chain(:tcp)
      Simulator.faults(ctx.sim, delay_ms: div(@timeout * 3, 2))
      {:ok, client} = connect(ctx)
      assert {:error, :timeout, client} = Client.read(client, 1, :holding, 199, 2)
      Simulator.clear_faults(ctx.sim)

      assert {:ok, _, client} = Client.read(client, 2, :holding, 199, 2)

      assert {[%{kind: :skipped, unit_id: 2, reasons: [:stale], bytes: stale}], _} =
               Client.take_anomalies(client)

      # The MBAP header of transaction 0, from unit 1.
      assert <<0::16, 0::16, _len::16, 1, 3, _::binary>> = stale
    end

    test "tcp: a reply that does not parse is kept as its PDU" do
      pdu = <<4, 3, 1, 2, 3>>

      port =
        reply_once(fn <<tid::16, _::binary>> -> <<tid::16, 0::16, 6::16, 1, pdu::binary>> end)

      {:ok, client} = Client.connect("127.0.0.1", port, :tcp, timeout: @timeout, max_timeouts: 1)

      assert {:error, :malformed_response, client} = Client.read(client, 1, :holding, 199, 2)

      assert {[%{kind: :rejected, unit_id: 1, reason: :malformed_response, bytes: ^pdu}], _} =
               Client.take_anomalies(client)
    end

    test "tcp: a malformed frame is kept as the bytes received" do
      frame = <<0, 0, 0, 7, 0, 3, 1, 4, 0>>
      port = reply_once(fn _request -> frame end)
      {:ok, client} = Client.connect("127.0.0.1", port, :tcp, timeout: @timeout, max_timeouts: 1)

      assert {:error, :malformed_frame, client} = Client.read(client, 1, :holding, 199, 2)

      assert {[%{kind: :rejected, reason: :malformed_frame, bytes: ^frame}], _} =
               Client.take_anomalies(client)
    end
  end

  # An endpoint that answers one request with `reply.(request)`.
  defp reply_once(reply) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)

    start_supervised!(
      {Task,
       fn ->
         {:ok, socket} = :gen_tcp.accept(listen)
         {:ok, request} = :gen_tcp.recv(socket, 0)
         :ok = :gen_tcp.send(socket, reply.(request))
         Process.sleep(:infinity)
       end},
      id: make_ref()
    )

    port
  end

  defp start_chain(framing, sim_opts \\ []) do
    sim_440 = Simulator.Profile.load!("elite_440", @profiles)
    sim_500 = Simulator.Profile.load!("elite_500", @profiles)
    import_ = "active_energy_import"

    meters = [
      Meter.new(1, sim_440, %{import_ => Decimal.new("123456.000")}),
      Meter.new(2, sim_440, %{import_ => Decimal.new("7.500")}),
      Meter.new(3, sim_500, %{import_ => Decimal.new("1234.500")}),
      %{Meter.new(4, sim_500, %{import_ => Decimal.new("1234.500")}) | word_order: :high_first}
    ]

    # A unique id, so a test can start a second endpoint beside its setup's.
    opts = [framing: framing, meters: meters] ++ sim_opts
    sim = start_supervised!(Supervisor.child_spec({Simulator, opts}, id: make_ref()))

    profiles =
      Map.new(["elite_440", "elite_500"], fn name ->
        {:ok, profile} = Profile.load(Path.join(@profiles, "#{name}.json"))
        {name, profile}
      end)

    %{sim: sim, port: Simulator.port(sim), framing: framing, profiles: profiles}
  end

  defp connect(ctx),
    do:
      Client.connect("127.0.0.1", ctx.port, ctx.framing,
        timeout: @timeout,
        max_timeouts: @max_timeouts
      )

  defp client!(ctx) do
    {:ok, client} = connect(ctx)
    client
  end

  # The endpoint frees its one connection slot only once it notices the close.
  defp reconnect_and_read(ctx, unit, tries) do
    {:ok, client} = connect(ctx)

    case Client.read(client, unit, :holding, 199, 2) do
      {:error, :closed, _} when tries > 1 ->
        Process.sleep(20)
        reconnect_and_read(ctx, unit, tries - 1)

      result ->
        result
    end
  end
end
