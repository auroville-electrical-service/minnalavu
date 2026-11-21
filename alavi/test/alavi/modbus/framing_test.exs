defmodule Alavi.Modbus.FramingTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest Alavi.Modbus.CRC
  doctest Alavi.Modbus.PDU

  alias Alavi.Modbus.{CRC, Framing, PDU, Selector}

  describe "encode/4" do
    test "RTU request matches a published example frame" do
      {:ok, pdu} = PDU.read_request(:input, 0, 2)
      assert Framing.encode(:rtu_over_tcp, 0, 1, pdu) == <<1, 4, 0, 0, 0, 2, 0x71, 0xCB>>
    end
  end

  describe "encode_selector/4" do
    test "frames a selector write as it frames a read" do
      {:ok, w440} = Selector.request("elite_440", :history, 1, 6)

      assert Framing.encode_selector(:tcp, 7, 1, w440) ==
               <<7::16, 0::16, 6::16, 1, 6, 520::16, 1::16>>

      assert <<1, 6, 520::16, 1::16, _crc::16>> =
               Framing.encode_selector(:rtu_over_tcp, 0, 1, w440)

      {:ok, w500} = Selector.request("elite_500", :history, 1, 6)

      assert Framing.encode_selector(:tcp, 7, 1, w500) ==
               <<7::16, 0::16, 9::16, 1, 16, 900::16, 1::16, 2, 1::16>>
    end
  end

  describe "decode_response/2" do
    test "an RTU echo of a selector write decodes" do
      for pdu <- [<<6, 520::16, 1::16>>, <<16, 900::16, 1::16>>] do
        frame = CRC.append(<<1, pdu::binary>>)
        assert :incomplete = Framing.decode_response(:rtu_over_tcp, binary_part(frame, 0, 7))
        assert {:ok, %{pdu: ^pdu}, ""} = Framing.decode_response(:rtu_over_tcp, frame)
      end
    end

    test "RTU response with a corrupted CRC is rejected" do
      frame = CRC.append(<<1, 4, 4, 0, 1, 0, 2>>)
      corrupted = binary_part(frame, 0, byte_size(frame) - 1) <> <<0>>
      assert {:error, :bad_crc} = Framing.decode_response(:rtu_over_tcp, corrupted)
    end

    property "every strict prefix of a response frame is incomplete, the whole frame decodes" do
      check all framing <- member_of([:tcp, :rtu_over_tcp]),
                words <- list_of(integer(0..0xFFFF), min_length: 1, max_length: 125),
                tid <- integer(0..0xFFFF),
                unit <- integer(1..247) do
        pdu = <<3, length(words) * 2, for(w <- words, into: <<>>, do: <<w::16>>)::binary>>
        frame = response_frame(framing, tid, unit, pdu)

        for n <- 0..(byte_size(frame) - 1) do
          assert :incomplete == Framing.decode_response(framing, binary_part(frame, 0, n))
        end

        assert {:ok, %{unit_id: ^unit, pdu: ^pdu}, ""} = Framing.decode_response(framing, frame)
        assert {:ok, ^words} = PDU.parse_response(:holding, length(words), pdu)
      end
    end

    property "arbitrary bytes never crash the decoders" do
      check all framing <- member_of([:tcp, :rtu_over_tcp]), bytes <- binary(max_length: 300) do
        result = Framing.decode_response(framing, bytes)

        assert match?({:ok, _, _}, result) or result in [:incomplete] or
                 match?({:error, _}, result)
      end
    end
  end

  describe "stale_reply/1" do
    test "a stale frame's unit, and its data or its exception code" do
      assert Framing.stale_reply(response_frame(:tcp, 4, 1, <<4, 2, 0, 1>>)) == {1, :data}
      assert Framing.stale_reply(response_frame(:tcp, 4, 7, <<3, 2, 0, 1>>)) == {7, :data}

      assert Framing.stale_reply(response_frame(:tcp, 4, 3, <<0x84, 0x0B>>)) ==
               {3, {:exception, 11}}
    end

    test "bytes that are not one read's frame are nil" do
      frame = response_frame(:tcp, 4, 1, <<4, 2, 0, 1>>)

      for bytes <- [
            frame <> frame,
            binary_part(frame, 0, 5),
            response_frame(:tcp, 4, 1, <<0x0B>>),
            response_frame(:tcp, 4, 1, <<6, 0, 1, 0, 2>>),
            response_frame(:tcp, 4, 1, <<0x84, 0>>),
            <<0xAA>>
          ],
          do: assert(Framing.stale_reply(bytes) == nil)
    end
  end

  describe "take_reply/3" do
    test "take_reply skips a TCP reply to another request and rejects one from another unit" do
      expected = %{transaction_id: 5, unit_id: 1, function_code: 4}
      stale = response_frame(:tcp, 4, 1, <<4, 2, 0, 1>>)
      reply = response_frame(:tcp, 5, 1, <<4, 2, 0, 2>>)

      assert {:skip, :stale, ^reply} = Framing.take_reply(:tcp, stale <> reply, expected)
      assert {:ok, <<4, 2, 0, 2>>, ""} = Framing.take_reply(:tcp, reply, expected)
      other_unit = response_frame(:tcp, 5, 2, <<4, 2, 0, 2>>)
      assert {:error, :unexpected_response} = Framing.take_reply(:tcp, other_unit, expected)
    end

    test "take_reply drops one byte of RTU noise that starts like the reply and fails its CRC" do
      expected = %{transaction_id: 0, unit_id: 1, function_code: 4}
      pdu = <<4, 4, 0, 1, 0, 2>>
      buffer = <<1, 4>> <> response_frame(:rtu_over_tcp, 0, 1, pdu)
      assert {{:ok, ^pdu, ""}, [:bad_crc, :noise]} = take_all(:rtu_over_tcp, buffer, expected)
    end

    test "take_reply waits on a lone byte that could start the RTU reply" do
      expected = %{transaction_id: 0, unit_id: 7, function_code: 3}
      assert :incomplete = Framing.take_reply(:rtu_over_tcp, <<7>>, expected)
      assert {:skip, :noise, ""} = Framing.take_reply(:rtu_over_tcp, <<8>>, expected)
    end

    property "RTU noise before the reply is skipped" do
      check all unit <- integer(1..247),
                noise <- list_of(filter(integer(0..255), &(&1 != unit)), max_length: 20),
                words <- list_of(integer(0..0xFFFF), min_length: 1, max_length: 125) do
        pdu = <<4, length(words) * 2, for(w <- words, into: <<>>, do: <<w::16>>)::binary>>
        buffer = :binary.list_to_bin(noise) <> response_frame(:rtu_over_tcp, 0, unit, pdu)
        expected = %{transaction_id: 0, unit_id: unit, function_code: 4}

        assert {{:ok, ^pdu, ""}, skipped} = take_all(:rtu_over_tcp, buffer, expected)
        assert length(skipped) == length(noise)
      end
    end

    property "arbitrary bytes never crash take_reply" do
      check all framing <- member_of([:tcp, :rtu_over_tcp]),
                bytes <- binary(max_length: 300),
                tid <- integer(0..0xFFFF),
                unit <- integer(1..247),
                fc <- member_of([3, 4]) do
        expected = %{transaction_id: tid, unit_id: unit, function_code: fc}
        {result, _skipped} = take_all(framing, bytes, expected)
        assert match?({:ok, _, _}, result) or result == :incomplete or match?({:error, _}, result)
      end
    end
  end

  defp take_all(framing, buffer, expected, skipped \\ []) do
    case Framing.take_reply(framing, buffer, expected) do
      {:skip, why, rest} -> take_all(framing, rest, expected, [why | skipped])
      result -> {result, Enum.reverse(skipped)}
    end
  end

  defp response_frame(:tcp, tid, unit, pdu),
    do: <<tid::16, 0::16, byte_size(pdu) + 1::16, unit, pdu::binary>>

  defp response_frame(:rtu_over_tcp, _tid, unit, pdu), do: CRC.append(<<unit, pdu::binary>>)
end
