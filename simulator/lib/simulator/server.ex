defmodule Simulator.Server do
  # Handlers ask this process for every response, so values and faults changed
  # mid-test take effect on the next request.

  use GenServer

  alias Simulator.{Faults, Meter, Protocol}

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    listen_opts = [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}]

    case :gen_tcp.listen(Keyword.fetch!(opts, :port), listen_opts) do
      {:ok, listen} ->
        server = self()
        acceptor = spawn_link(fn -> accept(listen, server) end)

        {:ok,
         %{
           listen: listen,
           acceptor: acceptor,
           framing: Keyword.fetch!(opts, :framing),
           meters: Keyword.fetch!(opts, :meters),
           max_connections: Keyword.fetch!(opts, :max_connections),
           missing_units: Keyword.fetch!(opts, :missing_units),
           faults: %Faults{},
           handlers: MapSet.new()
         }}

      {:error, reason} ->
        {:stop, {:listen, reason}}
    end
  end

  @impl true
  def handle_call(:port, _from, state) do
    {:ok, port} = :inet.port(state.listen)
    {:reply, port, state}
  end

  def handle_call(:admit, _from, state) do
    if MapSet.size(state.handlers) < state.max_connections do
      framing = state.framing
      server = self()
      handler = spawn_link(fn -> handle(framing, server) end)
      {:reply, {:ok, handler}, %{state | handlers: MapSet.put(state.handlers, handler)}}
    else
      {:reply, :reject, state}
    end
  end

  def handle_call({:respond, unit_id, pdu}, _from, state) do
    response = Protocol.respond(state.meters, state.faults, unit_id, pdu, state.missing_units)
    {:reply, {response, state.faults}, state}
  end

  def handle_call({:put, unit_id, key, value}, _from, state),
    do: {:reply, :ok, change(state, unit_id, &Meter.put(&1, key, value))}

  def handle_call({:identify, unit_id, check, value}, _from, state),
    do: {:reply, :ok, change(state, unit_id, &Meter.identify(&1, check, value))}

  def handle_call({:name, unit_id, name, value}, _from, state),
    do: {:reply, :ok, change(state, unit_id, &Meter.name(&1, name, value))}

  def handle_call({:faults, changes}, _from, state),
    do: {:reply, :ok, %{state | faults: struct!(state.faults, changes)}}

  @impl true
  def handle_info({:EXIT, acceptor, reason}, %{acceptor: acceptor} = state),
    do: {:stop, reason, state}

  def handle_info({:EXIT, pid, _reason}, state),
    do: {:noreply, %{state | handlers: MapSet.delete(state.handlers, pid)}}

  @impl true
  def terminate(_reason, state), do: :gen_tcp.close(state.listen)

  defp change(state, unit_id, change) do
    meters =
      Enum.map(state.meters, fn
        %Meter{unit_id: ^unit_id} = meter -> change.(meter)
        meter -> meter
      end)

    %{state | meters: meters}
  end

  defp accept(listen, server) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        hand_over(socket, GenServer.call(server, :admit))
        accept(listen, server)

      {:error, :closed} ->
        :ok
    end
  end

  # A full endpoint closes extra connections at once, as many Ethernet bridges do.
  defp hand_over(socket, :reject), do: :gen_tcp.close(socket)

  defp hand_over(socket, {:ok, handler}) do
    :ok = :gen_tcp.controlling_process(socket, handler)
    send(handler, {:socket, socket})
  end

  defp handle(framing, server) do
    receive do
      {:socket, socket} -> serve(socket, framing, server, <<>>)
    end
  end

  defp serve(socket, framing, server, buffer) do
    case Protocol.decode_request(framing, buffer) do
      {:ok, request, rest} ->
        reply(socket, framing, server, request)
        serve(socket, framing, server, rest)

      :incomplete ->
        receive_more(socket, framing, server, buffer)

      {:error, :bad_crc} ->
        # A meter ignores a corrupted frame; the stream is lost, so drop it.
        serve(socket, framing, server, <<>>)
    end
  end

  defp receive_more(socket, framing, server, buffer) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, bytes} -> serve(socket, framing, server, buffer <> bytes)
      {:error, _closed} -> :gen_tcp.close(socket)
    end
  end

  defp reply(socket, framing, server, request) do
    case GenServer.call(server, {:respond, request.unit_id, request.pdu}) do
      {:silent, _faults} ->
        :ok

      {{:reply, pdu}, faults} ->
        send_response(socket, framing, faults, request, pdu)

      {{:reply_as, unit_id, pdu}, faults} ->
        send_response(socket, framing, faults, %{request | unit_id: unit_id}, pdu)
    end
  end

  defp send_response(socket, framing, faults, request, pdu) do
    Process.sleep(faults.delay_ms)
    :gen_tcp.send(socket, Protocol.encode_response(framing, faults, request, pdu))
  end
end
