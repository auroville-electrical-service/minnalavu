defmodule Simulator.Protocol do
  @moduledoc """
  Server side of Modbus TCP and RTU-over-TCP for read requests, with faults.
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

  # Every read request is 8 bytes in RTU framing: unit, fc, address, count, CRC.
  def decode_request(:rtu_over_tcp, <<body::binary-size(6), crc::little-16, tail::binary>>) do
    <<unit, pdu::binary>> = body

    if crc(body) == crc,
      do: {:ok, %{transaction_id: 0, unit_id: unit, pdu: pdu}, tail},
      else: {:error, :bad_crc}
  end

  def decode_request(_framing, _buffer), do: :incomplete

  # contract: test/simulator/protocol_test.exs "respond/5"
  @doc "The response PDU for a request, or `:silent` when nothing would answer."
  @spec respond([Meter.t()], Faults.t(), 0..255, binary(), missing_units()) ::
          {:reply, binary()} | :silent
  def respond(meters, %Faults{} = faults, unit_id, <<fc, _::binary>> = pdu, missing \\ :silent) do
    cond do
      MapSet.member?(faults.silent_units, unit_id) -> :silent
      silent_read?(faults, unit_id, pdu) -> :silent
      faults.busy -> {:reply, exception(fc, @busy)}
      true -> meters |> Enum.find(&(&1.unit_id == unit_id)) |> answer(pdu, missing)
    end
  end

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

  defp silent_read?(faults, unit_id, <<_fc, address::16, _::binary>>),
    do: MapSet.member?(faults.silent_reads, {unit_id, address})

  defp silent_read?(_faults, _unit_id, _pdu), do: false

  defp answer(nil, _pdu, :silent), do: :silent

  defp answer(nil, <<fc, _::binary>>, :gateway_error),
    do: {:reply, exception(fc, @gateway_target_failed)}

  defp answer(meter, pdu, _missing), do: answer(meter, pdu)

  defp answer(meter, <<fc, address::16, count::16>>) when fc in [3, 4] and count in 1..125 do
    case Meter.read(meter, table(fc), address, count) do
      {:ok, words} ->
        {:reply, <<fc, count * 2, for(w <- words, into: <<>>, do: <<w::16>>)::binary>>}

      :unmapped ->
        {:reply, exception(fc, @illegal_address)}
    end
  end

  defp answer(_meter, <<fc, _address::16, _count::16>>) when fc in [3, 4],
    do: {:reply, exception(fc, @illegal_value)}

  defp answer(_meter, <<fc, _::binary>>), do: {:reply, exception(fc, @illegal_function)}

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
