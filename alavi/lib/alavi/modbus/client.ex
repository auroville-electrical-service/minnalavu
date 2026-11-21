defmodule Alavi.Modbus.Client do
  @moduledoc """
  A Modbus client for one TCP endpoint, one request in flight at a time. It
  sends reads, and the one write `Alavi.Modbus.Selector` builds. Reconnecting
  is not free: small bridges may hold a closed connection's slot for a while
  and refuse the next one.
  """

  alias Alavi.Modbus.{Framing, PDU, Selector}

  @enforce_keys [:socket, :framing, :timeout, :max_timeouts]
  defstruct [
    :socket,
    :framing,
    :timeout,
    :max_timeouts,
    transaction_id: 0,
    timeouts: 0,
    buffer: <<>>,
    anomalies: []
  ]

  @typedoc "`timeouts` counts timeouts in a row; `anomalies` are those not yet taken, newest first."
  @type t :: %__MODULE__{
          socket: :gen_tcp.socket() | nil,
          framing: Framing.t(),
          timeout: pos_integer(),
          max_timeouts: pos_integer(),
          transaction_id: Framing.transaction_id(),
          timeouts: non_neg_integer(),
          buffer: binary(),
          anomalies: [anomaly()]
        }

  @typedoc """
  Bytes from the endpoint that were not a usable reply, during a request to
  `unit_id`. `:skipped` is what was dropped ahead of the reply (or of the
  timeout, if none came), with `late`, the stale replies among it
  (`Alavi.Modbus.Framing.stale_reply/1`); `:rejected` is what was in hand when
  the request failed on it. `bytes` is not capped here; capping what is logged
  is the caller's.
  """
  @type anomaly ::
          %{
            kind: :skipped,
            unit_id: 1..247,
            reasons: [Framing.skipped(), ...],
            bytes: binary(),
            late: [Framing.late()]
          }
          | %{kind: :rejected, unit_id: 1..247, reason: error() | :echo_mismatch, bytes: binary()}

  @typedoc "`timeout` is in ms, for the connect and for each request."
  @type option :: {:timeout, pos_integer()} | {:max_timeouts, pos_integer()}

  @type error ::
          {:exception, PDU.exception_code()}
          | :invalid_request
          | :closed
          | :timeout
          | :unexpected_response
          | Framing.decode_error()
          | :malformed_response
          | {:socket, term()}

  @type write_error ::
          Selector.reply_error()
          | :closed
          | :timeout
          | :unexpected_response
          | Framing.decode_error()
          | {:socket, term()}

  @socket_opts [:binary, active: false, packet: :raw, nodelay: true]

  @spec connect(String.t(), :inet.port_number(), Framing.t(), [option()]) ::
          {:ok, t()} | {:error, {:socket, term()}}
  def connect(host, port, framing, opts) when framing in [:tcp, :rtu_over_tcp] do
    timeout = Keyword.fetch!(opts, :timeout)
    max_timeouts = max_timeouts(framing, opts)

    case :gen_tcp.connect(String.to_charlist(host), port, @socket_opts, timeout) do
      {:ok, socket} ->
        {:ok,
         %__MODULE__{
           socket: socket,
           framing: framing,
           timeout: timeout,
           max_timeouts: max_timeouts
         }}

      # Windows retries a refused connect (about 2 s to a loopback port) before
      # reporting it, so with a shorter timeout a refusing endpoint gives
      # :timeout there, where Linux and macOS give :econnrefused.
      {:error, reason} ->
        {:error, {:socket, reason}}
    end
  end

  @spec close(t()) :: t()
  def close(%__MODULE__{socket: nil} = client), do: client

  def close(%__MODULE__{socket: socket} = client) do
    :ok = :gen_tcp.close(socket)
    %{client | socket: nil, timeouts: 0, buffer: <<>>}
  end

  # contract: test/alavi/modbus/client_test.exs "take_anomalies/1"
  @spec take_anomalies(t()) :: {[anomaly()], t()}
  def take_anomalies(%__MODULE__{anomalies: anomalies} = client),
    do: {Enum.reverse(anomalies), %{client | anomalies: []}}

  # contract: test/alavi/modbus/client_test.exs "read/5"
  @doc "`address` is zero-based."
  @spec read(t(), 1..247, PDU.table(), non_neg_integer(), pos_integer()) ::
          {:ok, [PDU.word()], t()} | {:error, error(), t()}
  def read(%__MODULE__{socket: nil} = client, _unit_id, _table, _address, _count),
    do: {:error, :closed, client}

  def read(client, unit_id, table, address, count) when unit_id in 1..247 do
    case PDU.read_request(table, address, count) do
      {:ok, request} ->
        frame = &Framing.encode(&1, &2, unit_id, request)

        client
        |> exchange(unit_id, PDU.function_code(table), frame)
        |> parse(unit_id, table, count)

      {:error, :invalid_request} ->
        {:error, :invalid_request, client}
    end
  end

  def read(client, _unit_id, _table, _address, _count), do: {:error, :invalid_request, client}

  # contract: test/alavi/modbus/client_test.exs "write_selector/3"
  @doc """
  Sends one selector write, once: it is never retried here, since a write whose
  reply was lost may have landed. Any failure but a Modbus exception closes the
  connection, so a late echo cannot be taken for another reply. Returns after
  the selector's settle time.
  """
  @spec write_selector(t(), 1..247, Selector.t()) :: {:ok, t()} | {:error, write_error(), t()}
  def write_selector(%__MODULE__{socket: nil} = client, _unit_id, _request),
    do: {:error, :closed, client}

  def write_selector(client, unit_id, request) when unit_id in 1..247 do
    frame = &Framing.encode_selector(&1, &2, unit_id, request)

    client
    |> exchange(unit_id, Selector.function_code(request), frame)
    |> echoed(unit_id, request)
  end

  defp max_timeouts(:tcp, opts), do: Keyword.fetch!(opts, :max_timeouts)
  # RTU frames carry no transaction id, so a late reply could not be told from the next one.
  defp max_timeouts(:rtu_over_tcp, _opts), do: 1

  defp exchange(client, unit_id, function_code, encode) do
    tid = client.transaction_id
    client = %{client | transaction_id: rem(tid + 1, 0x10000)}
    expected = %{transaction_id: tid, unit_id: unit_id, function_code: function_code}
    frame = encode.(client.framing, tid)

    case :gen_tcp.send(client.socket, frame) do
      :ok -> await(client, expected, deadline(client.timeout), nil)
      {:error, reason} -> {:error, socket_error(reason), client}
    end
  end

  defp parse({:ok, pdu, client}, unit_id, table, count) do
    case PDU.parse_response(table, count, pdu) do
      {:ok, words} -> {:ok, words, %{client | timeouts: 0}}
      {:error, {:exception, _} = reason} -> fail(client, reason)
      {:error, reason} -> client |> rejected(unit_id, reason, pdu) |> fail(reason)
    end
  end

  # A read refused in step keeps the connection: a retry may be answered on it.
  defp parse({:error, {:in_step, reason}, client}, _unit_id, _table, _count),
    do: {:error, reason, client}

  defp parse({:error, reason, client}, _unit_id, _table, _count), do: fail(client, reason)

  defp echoed({:ok, pdu, client}, unit_id, request) do
    case Selector.parse_reply(request, pdu) do
      :ok ->
        Process.sleep(Selector.settle_ms(request))
        {:ok, %{client | timeouts: 0}}

      {:error, {:exception, _} = reason} ->
        {:error, reason, %{client | timeouts: 0}}

      {:error, :echo_mismatch} ->
        {:error, :echo_mismatch, client |> rejected(unit_id, :echo_mismatch, pdu) |> close()}
    end
  end

  defp echoed({:error, {:in_step, reason}, client}, _unit_id, _request),
    do: {:error, reason, close(client)}

  defp echoed({:error, reason, client}, _unit_id, _request), do: {:error, reason, close(client)}

  # A deadline reached after a bad CRC reports the corruption, not a plain timeout.
  defp await(client, expected, deadline, skipped) do
    case Framing.take_reply(client.framing, client.buffer, expected) do
      {:ok, pdu, _rest} ->
        {:ok, pdu, %{client | buffer: <<>>} |> noted(expected, skipped)}

      {:skip, why, rest} ->
        dropped = binary_part(client.buffer, 0, byte_size(client.buffer) - byte_size(rest))
        await(%{client | buffer: rest}, expected, deadline, skip(skipped, why, dropped))

      :incomplete ->
        receive_more(client, expected, deadline, skipped)

      {:rejected, reason, rest} ->
        frame = binary_part(client.buffer, 0, byte_size(client.buffer) - byte_size(rest))

        client =
          %{client | buffer: rest}
          |> noted(expected, skipped)
          |> rejected(expected.unit_id, reason, frame)

        {:error, {:in_step, reason}, client}

      {:error, reason} ->
        client =
          client |> noted(expected, skipped) |> rejected(expected.unit_id, reason, client.buffer)

        {:error, reason, client}
    end
  end

  defp receive_more(client, expected, deadline, skipped) do
    remaining = deadline - System.monotonic_time(:millisecond)

    with true <- remaining > 0,
         {:ok, bytes} <- :gen_tcp.recv(client.socket, 0, remaining) do
      await(%{client | buffer: client.buffer <> bytes}, expected, deadline, skipped)
    else
      false -> {:error, expired(skipped), noted(client, expected, skipped)}
      {:error, :timeout} -> {:error, expired(skipped), noted(client, expected, skipped)}
      {:error, reason} -> {:error, socket_error(reason), noted(client, expected, skipped)}
    end
  end

  defp skip(nil, why, dropped), do: %{reasons: [why], bytes: dropped, late: late(why, dropped)}

  defp skip(%{reasons: reasons, bytes: bytes, late: late}, why, dropped),
    do: %{
      reasons: Enum.uniq(reasons ++ [why]),
      bytes: bytes <> dropped,
      late: late ++ late(why, dropped)
    }

  defp late(:stale, dropped) do
    case Framing.stale_reply(dropped) do
      nil -> []
      reply -> [reply]
    end
  end

  defp late(_why, _dropped), do: []

  defp noted(client, _expected, nil), do: client

  defp noted(client, %{unit_id: unit_id}, skipped),
    do: note(client, Map.merge(%{kind: :skipped, unit_id: unit_id}, skipped))

  defp rejected(client, unit_id, reason, bytes),
    do: note(client, %{kind: :rejected, unit_id: unit_id, reason: reason, bytes: bytes})

  defp note(client, anomaly), do: %{client | anomalies: [anomaly | client.anomalies]}

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp expired(nil), do: :timeout
  defp expired(%{reasons: reasons}), do: if(:bad_crc in reasons, do: :bad_crc, else: :timeout)

  defp socket_error(:closed), do: :closed
  defp socket_error(reason), do: {:socket, reason}

  defp fail(client, {:exception, _} = reason), do: {:error, reason, %{client | timeouts: 0}}

  defp fail(%{timeouts: timeouts, max_timeouts: max} = client, :timeout) when timeouts + 1 < max,
    do: {:error, :timeout, %{client | timeouts: timeouts + 1}}

  defp fail(client, reason), do: {:error, reason, close(client)}
end
