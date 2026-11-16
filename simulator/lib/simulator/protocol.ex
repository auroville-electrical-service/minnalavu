defmodule Simulator.Protocol do
  @moduledoc """
  Server side of Modbus TCP and RTU-over-TCP for read requests and selector
  writes, with faults.
  """

  import Bitwise

  alias Simulator.{Faults, Meter}

  @type framing :: :tcp | :rtu_over_tcp
  @type request :: %{transaction_id: 0..0xFFFF, unit_id: 0..255, pdu: binary()}

  @typedoc """
  What a request for a unit with no meter gets. `:silent`: nothing, as on a bare
  RS-485 bus. `:gateway_error`: exception 0B, gateway target device failed to
  respond, as many Ethernet-to-RS-485 gateways send.
  """
  @type missing_units :: :silent | :gateway_error

  @illegal_function 1
  @illegal_address 2
  @illegal_value 3
  @busy 6
  @gateway_target_failed 0x0B

  # contract: test/simulator/protocol_test.exs "decode_request/2"
  @doc "Take one request frame off the front of `buffer`."
  @spec decode_request(framing(), binary()) ::
          {:ok, request(), binary()} | :incomplete | {:error, :bad_crc}
  def decode_request(:tcp, <<tid::16, _pid::16, len::16, unit, rest::binary>>)
      when len >= 2 and byte_size(rest) >= len - 1 do
    pdu_len = len - 1
    <<pdu::binary-size(^pdu_len), tail::binary>> = rest
    {:ok, %{transaction_id: tid, unit_id: unit, pdu: pdu}, tail}
  end

  # A function 16 request is 9 bytes and its data in RTU framing: unit, fc,
  # address, count, byte count, data, CRC. Every other is 8: unit, fc, two
  # words, CRC.
  def decode_request(:rtu_over_tcp, <<_unit, 16, _::32, byte_count, _::binary>> = buffer),
    do: take_rtu(buffer, 7 + byte_count)

  def decode_request(:rtu_over_tcp, <<_unit, fc, _::binary>> = buffer) when fc != 16,
    do: take_rtu(buffer, 6)

  def decode_request(_framing, _buffer), do: :incomplete

  defp take_rtu(buffer, body_len) do
    case buffer do
      <<body::binary-size(^body_len), crc::little-16, tail::binary>> ->
        <<unit, pdu::binary>> = body

        if crc(body) == crc,
          do: {:ok, %{transaction_id: 0, unit_id: unit, pdu: pdu}, tail},
          else: {:error, :bad_crc}

      _ ->
        :incomplete
    end
  end

  # contract: test/simulator/protocol_test.exs "respond/6"
  @doc """
  The response PDU for a request at host time `host_ms`, or `:silent` when
  nothing would answer, or `:drop` when the connection is to close.
  `{:reply_as, unit, pdu}` is framed under `unit` instead of the unit asked for.
  `{:write, pdu, meter}` answers a selector write that `meter` now holds.
  """
  @spec respond([Meter.t()], Faults.t(), 0..255, binary(), missing_units(), integer()) ::
          {:reply, binary()}
          | {:reply_as, 0..255, binary()}
          | {:write, binary(), Meter.t()}
          | :silent
          | :drop
  def respond(meters, %Faults{} = faults, unit_id, <<fc, _::binary>> = pdu, missing, host_ms) do
    read = read_at(unit_id, pdu)
    span = span_at(unit_id, pdu)

    case fault(faults, unit_id, {read, span}, fc) do
      nil ->
        meters
        |> Enum.find(&(&1.unit_id == unit_id))
        |> answer(pdu, missing, host_ms)
        |> lost(MapSet.member?(faults.lost_writes, read))

      response ->
        response
    end
  end

  # What a fault answers instead of the meter, or nil when none does.
  defp fault(faults, unit_id, {read, span}, fc),
    do: unanswered(faults, unit_id, read) || refused(faults, unit_id, {read, span}, fc)

  defp unanswered(faults, unit_id, read) do
    cond do
      MapSet.member?(faults.silent_units, unit_id) -> :silent
      MapSet.member?(faults.dropped_requests, read) -> :drop
      MapSet.member?(faults.silent_reads, read) -> :silent
      true -> nil
    end
  end

  defp refused(faults, unit_id, {read, span}, fc) do
    cond do
      is_map_key(faults.two_byte_replies, unit_id) ->
        {:reply_as, faults.two_byte_replies[unit_id], <<@gateway_target_failed>>}

      is_map_key(faults.refused_reads, read) ->
        {:reply, exception(fc, faults.refused_reads[read])}

      is_map_key(faults.refused_spans, span) ->
        {:reply, exception(fc, faults.refused_spans[span])}

      fc in [6, 16] and is_map_key(faults.refused_writes, read) ->
        {:reply, exception(fc, faults.refused_writes[read])}

      faults.busy ->
        {:reply, exception(fc, @busy)}

      true ->
        nil
    end
  end

  defp lost({:write, echo, _meter}, true), do: {:reply, echo}
  defp lost(response, _lost), do: response

  # contract: test/simulator/protocol_test.exs "encode_response/4"
  @doc "Frame a response PDU, with the RTU faults (corrupt CRC, leading noise) applied."
  @spec encode_response(framing(), Faults.t(), request(), binary()) :: binary()
  def encode_response(:tcp, _faults, %{transaction_id: tid, unit_id: unit}, pdu),
    do: <<tid::16, 0::16, byte_size(pdu) + 1::16, unit, pdu::binary>>

  def encode_response(:rtu_over_tcp, faults, %{unit_id: unit}, pdu) do
    body = <<unit, pdu::binary>>
    crc = if faults.bad_crc, do: bxor(crc(body), 0xFFFF), else: crc(body)
    <<faults.noise::binary, body::binary, crc::little-16>>
  end

  defp read_at(unit_id, <<_fc, address::16, _::binary>>), do: {unit_id, address}
  defp read_at(_unit_id, _pdu), do: nil

  defp span_at(unit_id, <<fc, address::16, count::16>>) when fc in [3, 4],
    do: {unit_id, address, count}

  defp span_at(_unit_id, _pdu), do: nil

  defp answer(nil, _pdu, :silent, _host_ms), do: :silent

  defp answer(nil, <<fc, _::binary>>, :gateway_error, _host_ms),
    do: {:reply, exception(fc, @gateway_target_failed)}

  defp answer(meter, pdu, _missing, host_ms), do: answer(meter, pdu, host_ms)

  defp answer(meter, <<fc, address::16, count::16>>, host_ms)
       when fc in [3, 4] and count in 1..125 do
    case Meter.read(meter, table(fc), address, count, host_ms) do
      {:ok, words} ->
        {:reply, <<fc, count * 2, for(w <- words, into: <<>>, do: <<w::16>>)::binary>>}

      :unmapped ->
        {:reply, exception(fc, @illegal_address)}
    end
  end

  defp answer(_meter, <<fc, _address::16, _count::16>>, _host_ms) when fc in [3, 4],
    do: {:reply, exception(fc, @illegal_value)}

  defp answer(meter, <<6, address::16, value::16>> = pdu, host_ms),
    do: written(Meter.write(meter, 6, address, value, host_ms), 6, pdu)

  defp answer(meter, <<16, address::16, 1::16, 2, value::16>>, host_ms),
    do: written(Meter.write(meter, 16, address, value, host_ms), 16, <<16, address::16, 1::16>>)

  defp answer(_meter, <<16, _::binary>>, _host_ms), do: {:reply, exception(16, @illegal_value)}

  defp answer(_meter, <<fc, _::binary>>, _host_ms), do: {:reply, exception(fc, @illegal_function)}

  defp written({:ok, meter}, _fc, echo), do: {:write, echo, meter}
  defp written({:exception, code}, fc, _echo), do: {:reply, exception(fc, code)}

  defp exception(fc, code), do: <<fc ||| 0x80, code>>

  defp table(3), do: :holding
  defp table(4), do: :input

  defp crc(data) do
    for <<byte <- data>>, reduce: 0xFFFF do
      acc -> Enum.reduce(1..8, bxor(acc, byte), fn _, c -> crc_shift(c) end)
    end
  end

  defp crc_shift(c) when (c &&& 1) == 1, do: bxor(c >>> 1, 0xA001)
  defp crc_shift(c), do: c >>> 1
end
