defmodule Alavi.ScriptedEndpoint do
  @moduledoc """
  A Modbus TCP endpoint that answers each read request, in the order they
  arrive, with the next of a script, one connection at a time. Each request is
  sent to the owner as `{:scripted_read, [unit_id, table, address, count],
  gap_ms}`, `gap_ms` being the time since the previous answer (or the start).

  A script entry is `{:words, words}`, `{:exception, code}`, `:timeout` (no
  answer), `:closed` (the connection is closed unanswered),
  `:malformed_response` (a reply with no registers), or `:unreachable`: from
  there on the endpoint refuses connections, which it can only start doing
  at the start or after a `:closed`. A request past the script goes unanswered.
  """

  @type entry ::
          {:words, [0..0xFFFF]}
          | {:exception, 1..255}
          | :timeout
          | :closed
          | :malformed_response
          | :unreachable

  @tables %{3 => "holding", 4 => "input"}

  @doc "Start an endpoint following `script`, supervised by the calling test; returns its port."
  @spec start!([entry()]) :: :inet.port_number()
  def start!(script) do
    owner = self()
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    state = %{listen: listen, owner: owner, script: script, at: now()}

    task =
      ExUnit.Callbacks.start_supervised!(
        {Task, fn -> receive(do: (:listen -> accepting(state))) end},
        id: make_ref()
      )

    :ok = :gen_tcp.controlling_process(listen, task)
    send(task, :listen)
    port
  end

  defp accepting(%{script: [:unreachable | _]} = state) do
    :gen_tcp.close(state.listen)
    Process.sleep(:infinity)
  end

  defp accepting(state) do
    {:ok, socket} = :gen_tcp.accept(state.listen)
    serving(socket, state)
  end

  defp serving(socket, state) do
    case :gen_tcp.recv(socket, 12) do
      {:ok, <<tid::16, 0::16, 6::16, unit, fc, address::16, count::16>>} ->
        send(state.owner, {:scripted_read, [unit, @tables[fc], address, count], now() - state.at})
        {entry, script} = pop(state.script)
        answer(entry, socket, {tid, unit, fc}, %{state | script: script})

      {:error, _closed} ->
        :gen_tcp.close(socket)
        accepting(state)
    end
  end

  defp pop([]), do: {:timeout, []}
  defp pop([entry | rest]), do: {entry, rest}

  defp answer(:timeout, socket, _request, state), do: serving(socket, state)

  defp answer(:closed, socket, _request, state) do
    # Refuse before closing, so that the client's reconnect finds the port closed.
    if match?([:unreachable | _], state.script), do: :gen_tcp.close(state.listen)
    :gen_tcp.close(socket)
    accepting(state)
  end

  defp answer(entry, socket, {tid, unit, fc}, state) do
    pdu = pdu(entry, fc)
    :ok = :gen_tcp.send(socket, <<tid::16, 0::16, byte_size(pdu) + 1::16, unit, pdu::binary>>)
    serving(socket, %{state | at: now()})
  end

  defp pdu({:words, words}, fc),
    do: <<fc, 2 * length(words), for(w <- words, into: <<>>, do: <<w::16>>)::binary>>

  defp pdu({:exception, code}, fc), do: <<fc + 0x80, code>>
  defp pdu(:malformed_response, fc), do: <<fc, 0>>

  defp now, do: System.monotonic_time(:millisecond)
end
