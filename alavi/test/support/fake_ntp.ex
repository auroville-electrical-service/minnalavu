defmodule Alavi.FakeNtp do
  @moduledoc """
  An SNTP server on a loopback address for tests (127.0.0.1 unless given;
  several on one port need an address each, which Linux has throughout
  127.0.0.0/8). Each request is sent to the test
  process as `{:ntp_request, ip, request}`, and answered as `respond` says:
  `{:reply, packet}`, built from the request with `reply/2`, or `:drop`. The
  server's times are nanoseconds since the Unix epoch, as `Alavi.Sntp` gives them.
  """

  import Bitwise

  @unix_epoch 2_208_988_800
  @nanos 1_000_000_000

  @type respond :: (binary() -> {:reply, binary()} | :drop)

  @spec start!(respond(), :inet.ip4_address(), :inet.port_number()) :: :inet.port_number()
  def start!(respond, ip \\ {127, 0, 0, 1}, port \\ 0) do
    test = self()

    {:ok, pid} =
      Task.start_link(fn ->
        {:ok, socket} = :gen_udp.open(port, [:binary, ip: ip, active: false])
        {:ok, port} = :inet.port(socket)
        send(test, {:fake_ntp, self(), port})
        serve(socket, ip, test, respond)
      end)

    receive do
      {:fake_ntp, ^pid, port} -> port
    after
      1_000 -> raise "the fake NTP server did not start"
    end
  end

  @doc "An answer to `request`: stratum 2, both times `at`, unless `fields` says otherwise."
  @spec reply(binary(), keyword()) :: binary()
  def reply(<<_::binary-40, nonce::binary-8>>, fields \\ []) do
    f =
      Map.merge(
        %{
          leap: 0,
          version: 4,
          mode: 4,
          stratum: 2,
          reference_id: 0xC0000283,
          origin: nonce,
          at: 1_793_491_208_215_003_051
        },
        Map.new(fields)
      )

    received = Map.get(f, :received, f.at)
    sent = Map.get(f, :sent, f.at)

    <<f.leap::2, f.version::3, f.mode::3, f.stratum::8, 6::8, -23::signed-8, 0::32, 0::32,
      f.reference_id::32, 0::64, f.origin::binary-8, timestamp(received)::binary,
      timestamp(sent)::binary>>
  end

  # The fraction rounded up, so that truncating it gives back `ns` exactly.
  defp timestamp(ns) do
    seconds = div(ns, @nanos) + @unix_epoch
    fraction = div(rem(ns, @nanos) * (1 <<< 32) + @nanos - 1, @nanos)
    <<seconds::32, fraction::32>>
  end

  defp serve(socket, ip, test, respond) do
    {:ok, {address, from, request}} = :gen_udp.recv(socket, 0)
    send(test, {:ntp_request, ip, request})

    case respond.(request) do
      {:reply, packet} -> :ok = :gen_udp.send(socket, address, from, packet)
      :drop -> :ok
    end

    serve(socket, ip, test, respond)
  end
end
