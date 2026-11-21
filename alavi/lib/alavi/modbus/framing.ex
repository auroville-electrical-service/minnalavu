defmodule Alavi.Modbus.Framing do
  @moduledoc """
  - `:tcp` is Modbus TCP: a 7-byte MBAP header carrying a transaction id, no CRC.
  - `:rtu_over_tcp` is the serial RTU frame (unit id, PDU, CRC) sent as-is over TCP,
    as many RS-485-to-Ethernet bridges do. It has no transaction id, so a response
    is matched to its request only by order.
  """

  alias Alavi.Modbus.{CRC, PDU, Selector}

  @type t :: :tcp | :rtu_over_tcp
  @type unit_id :: 0..255
  @type transaction_id :: 0..0xFFFF
  @type frame :: %{unit_id: unit_id(), transaction_id: transaction_id() | nil, pdu: binary()}
  @type decode_error :: :bad_crc | :malformed_frame
  @typedoc "What the reply to one request must carry."
  @type expected :: %{
          transaction_id: transaction_id(),
          unit_id: unit_id(),
          function_code: 3 | 4 | Selector.function_code()
        }
  @type skipped :: :stale | :noise | :bad_crc
  @typedoc "A stale reply's unit, and whether it carried data or an exception, with its code."
  @type late :: {unit_id(), :data | {:exception, 1..255}}

  # contract: test/alavi/modbus/framing_test.exs "encode/4"
  @spec encode(t(), transaction_id(), unit_id(), PDU.t()) :: binary()
  def encode(framing, transaction_id, unit_id, request),
    do: frame(framing, transaction_id, unit_id, PDU.bytes(request))

  # contract: test/alavi/modbus/framing_test.exs "encode_selector/4"
  @spec encode_selector(t(), transaction_id(), unit_id(), Selector.t()) :: binary()
  def encode_selector(framing, transaction_id, unit_id, request),
    do: frame(framing, transaction_id, unit_id, Selector.bytes(request))

  defp frame(:tcp, transaction_id, unit_id, pdu),
    do: <<transaction_id::16, 0::16, byte_size(pdu) + 1::16, unit_id, pdu::binary>>

  defp frame(:rtu_over_tcp, _transaction_id, unit_id, pdu),
    do: CRC.append(<<unit_id, pdu::binary>>)

  # contract: test/alavi/modbus/framing_test.exs "decode_response/2"
  @doc """
  RTU decoding assumes the frame answers a read (function code 03/04), a
  selector write (06/16, a fixed four bytes after the code) or is an exception.
  """
  @spec decode_response(t(), binary()) ::
          {:ok, frame(), binary()} | :incomplete | {:error, decode_error()}
  def decode_response(:tcp, <<tid::16, 0::16, len::16, unit_id, rest::binary>>)
      when len in 2..254 do
    pdu_len = len - 1

    case rest do
      <<pdu::binary-size(^pdu_len), tail::binary>> ->
        {:ok, %{unit_id: unit_id, transaction_id: tid, pdu: pdu}, tail}

      _ ->
        :incomplete
    end
  end

  def decode_response(:tcp, <<_tid::16, _pid::16, _len::16, _unit, _rest::binary>>),
    do: {:error, :malformed_frame}

  def decode_response(:tcp, _buffer), do: :incomplete

  def decode_response(:rtu_over_tcp, <<_unit, fc, _::binary>> = buffer) when fc >= 0x80,
    do: take_rtu(buffer, 3)

  def decode_response(:rtu_over_tcp, <<_unit, fc, count, _::binary>> = buffer)
      when fc in [3, 4],
      do: take_rtu(buffer, 3 + count)

  def decode_response(:rtu_over_tcp, <<_unit, fc, _::binary>> = buffer) when fc in [6, 16],
    do: take_rtu(buffer, 6)

  def decode_response(:rtu_over_tcp, <<_unit, fc, _::binary>>) when fc not in [3, 4],
    do: {:error, :malformed_frame}

  def decode_response(:rtu_over_tcp, _buffer), do: :incomplete

  # contract: test/alavi/modbus/framing_test.exs "take_reply/3"
  @doc """
  `{:skip, why, rest}` drops what is in front of the reply; call again on `rest`.
  A TCP frame with the right transaction id but another unit is
  `:unexpected_response`; a stale one (`:stale`) is skipped, so a device that echoes
  the wrong id times out rather than failing as unexpected. `{:rejected, why, rest}`:
  the frame was not the reply, but was taken whole and leaves the stream in step.
  """
  @spec take_reply(t(), binary(), expected()) ::
          {:ok, binary(), binary()}
          | {:skip, skipped(), binary()}
          | {:rejected, :unexpected_response, binary()}
          | :incomplete
          | {:error, decode_error() | :unexpected_response}
  def take_reply(:tcp, buffer, expected) do
    case decode_response(:tcp, buffer) do
      {:ok, frame, rest} -> tcp_reply(frame, rest, expected)
      other -> other
    end
  end

  def take_reply(:rtu_over_tcp, <<unit, fc, _::binary>> = buffer, %{
        unit_id: unit,
        function_code: read_fc
      })
      when fc == read_fc or fc == read_fc + 0x80 do
    case decode_response(:rtu_over_tcp, buffer) do
      {:ok, %{pdu: pdu}, rest} -> {:ok, pdu, rest}
      :incomplete -> :incomplete
      {:error, :bad_crc} -> {:skip, :bad_crc, binary_part(buffer, 1, byte_size(buffer) - 1)}
    end
  end

  def take_reply(:rtu_over_tcp, <<unit>>, %{unit_id: unit}), do: :incomplete
  def take_reply(:rtu_over_tcp, <<>>, _expected), do: :incomplete
  def take_reply(:rtu_over_tcp, <<_noise, rest::binary>>, _expected), do: {:skip, :noise, rest}

  defp tcp_reply(%{transaction_id: tid, unit_id: unit, pdu: pdu}, rest, %{
         transaction_id: tid,
         unit_id: unit
       }),
       do: {:ok, pdu, rest}

  # A gateway's lone 0B under a byte of its own (one fixed byte per gateway on
  # site), not the unit asked: taken whole, so the connection stays in step.
  defp tcp_reply(%{transaction_id: tid, pdu: <<0x0B>>}, rest, %{transaction_id: tid}),
    do: {:rejected, :unexpected_response, rest}

  defp tcp_reply(%{transaction_id: tid}, _rest, %{transaction_id: tid}),
    do: {:error, :unexpected_response}

  defp tcp_reply(_frame, rest, _expected), do: {:skip, :stale, rest}

  # contract: test/alavi/modbus/framing_test.exs "stale_reply/1"
  @doc """
  Whom a stale TCP frame, skipped whole, came from: a read's data, or an
  exception with its code. nil for bytes that are not one such frame.
  """
  @spec stale_reply(binary()) :: late() | nil
  def stale_reply(bytes) do
    case decode_response(:tcp, bytes) do
      {:ok, %{unit_id: unit, pdu: <<fc, _::binary>>}, <<>>} when fc in [0x03, 0x04] ->
        {unit, :data}

      {:ok, %{unit_id: unit, pdu: <<fc, code>>}, <<>>} when fc in [0x83, 0x84] and code > 0 ->
        {unit, {:exception, code}}

      _other ->
        nil
    end
  end

  defp take_rtu(buffer, body_len) do
    with <<body::binary-size(^body_len), crc::little-16, tail::binary>> <- buffer,
         true <- CRC.checksum(body) == crc do
      <<unit_id, pdu::binary>> = body
      {:ok, %{unit_id: unit_id, transaction_id: nil, pdu: pdu}, tail}
    else
      false -> {:error, :bad_crc}
      _ -> :incomplete
    end
  end
end
