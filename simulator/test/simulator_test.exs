defmodule SimulatorTest do
  use ExUnit.Case, async: true

  alias Simulator.{Meter, Profile}

  describe "faults/2" do
    test "tcp: a gateway's two-byte reply goes out as an MBAP header and 0B, under the unit byte set" do
      meters = [
        Meter.new(1, Profile.load!("elite_440")),
        Meter.new(2, Profile.load!("elite_440"))
      ]

      sim = start_supervised!({Simulator, framing: :tcp, meters: meters})
      Simulator.faults(sim, two_byte_replies: [{1, 7}])

      {:ok, socket} =
        :gen_tcp.connect(~c"127.0.0.1", Simulator.port(sim), [:binary, active: false])

      assert request(socket, 0x1C, 1) == <<0x00, 0x1C, 0, 0, 0, 2, 7, 0x0B>>
      assert <<0x00, 0x1D, 0, 0, 0, 7, 2, 3, 4, _::32>> = request(socket, 0x1D, 2)
    end

    test "a lost write is echoed, and its selector keeps its value; other selectors take theirs" do
      {sim, port} = start_sim!()
      Simulator.faults(sim, lost_writes: [{1, 520}])
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

      assert send_pdu(socket, 1, <<6, 520::16, 3::16>>) == <<6, 520::16, 3::16>>
      assert send_pdu(socket, 2, <<3, 520::16, 1::16>>) == <<3, 2, 0::16>>
      assert send_pdu(socket, 3, <<6, 700::16, 3::16>>) == <<6, 700::16, 3::16>>
      assert send_pdu(socket, 4, <<3, 700::16, 1::16>>) == <<3, 2, 3::16>>
    end
  end

  describe "select/4" do
    test "a selector set behind the client's back reads back as set" do
      {sim, port} = start_sim!()
      :ok = Simulator.select(sim, 1, 801, 19)
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
      assert send_pdu(socket, 1, <<3, 801::16, 1::16>>) == <<3, 2, 19::16>>
    end
  end

  describe "offline/1" do
    test "an open connection gets no reply, and new connects time out rather than being refused" do
      {sim, port} = start_sim!()
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
      assert <<0x00, 0x01, _::binary>> = request(socket, 1, 1)

      :ok = Simulator.offline(sim)
      :ok = Simulator.offline(sim)

      :ok = :gen_tcp.send(socket, <<2::16, 0::16, 6::16, 1, 3, 199::16, 2::16>>)
      assert :gen_tcp.recv(socket, 0, 200) == {:error, :timeout}

      for _ <- 1..3 do
        assert :gen_tcp.connect(~c"127.0.0.1", port, [active: false], 200) == {:error, :timeout}
      end
    end

    test "a connect timer's message left behind by going offline does not stop the endpoint" do
      {sim, port} = start_sim!()
      :ok = Simulator.offline(sim)
      send(sim, {:timeout, make_ref(), :inet})
      :ok = Simulator.online(sim)

      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 1_000)
      assert <<0x00, 0x04, _::binary>> = request(socket, 4, 1)
    end
  end

  describe "online/1" do
    test "the endpoint answers new connections again, on the same port" do
      {sim, port} = start_sim!()
      :ok = Simulator.online(sim)
      :ok = Simulator.offline(sim)
      :ok = Simulator.online(sim)

      assert Simulator.port(sim) == port
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 1_000)
      assert <<0x00, 0x03, _::binary>> = request(socket, 3, 1)
    end
  end

  defp start_sim! do
    sim =
      start_supervised!(
        {Simulator, framing: :tcp, meters: [Meter.new(1, Profile.load!("elite_440"))]}
      )

    {sim, Simulator.port(sim)}
  end

  # One request to unit 1, and the PDU of its reply.
  defp send_pdu(socket, tid, pdu) do
    :ok = :gen_tcp.send(socket, <<tid::16, 0::16, byte_size(pdu) + 1::16, 1, pdu::binary>>)
    {:ok, <<^tid::16, 0::16, len::16>>} = :gen_tcp.recv(socket, 6, 1_000)
    {:ok, <<1, reply::binary>>} = :gen_tcp.recv(socket, len, 1_000)
    reply
  end

  # A read of two holding registers at 199, and the whole reply to it.
  defp request(socket, tid, unit) do
    :ok = :gen_tcp.send(socket, <<tid::16, 0::16, 6::16, unit, 3, 199::16, 2::16>>)
    {:ok, <<_::binary-size(4), len::16>> = header} = :gen_tcp.recv(socket, 6, 1_000)
    {:ok, rest} = :gen_tcp.recv(socket, len, 1_000)
    header <> rest
  end
end
