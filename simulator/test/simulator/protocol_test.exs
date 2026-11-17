defmodule Simulator.ProtocolTest do
  use ExUnit.Case, async: true

  alias Simulator.{Faults, Meter, Profile, Protocol}

  setup do
    meter =
      Meter.new(1, Profile.load!("elite_500"), %{"active_energy_import" => Decimal.new("1.5")})

    %{meters: [meter]}
  end

  describe "respond/5" do
    test "reads mapped holding registers", %{meters: meters} do
      # 1.5 as an f64 is 0x3FF8_0000_0000_0000; low word first on the wire.
      assert {:reply, <<3, 8, 0::16, 0::16, 0::16, 0x3FF8::16>>} =
               Protocol.respond(meters, %Faults{}, 1, <<3, 11_149::16, 4::16>>)
    end

    test "unmapped address is exception 02", %{meters: meters} do
      assert {:reply, <<0x84, 2>>} =
               Protocol.respond(meters, %Faults{}, 1, <<4, 11_149::16, 2::16>>)
    end

    test "write function codes are exception 01", %{meters: meters} do
      assert {:reply, <<0x86, 1>>} =
               Protocol.respond(meters, %Faults{}, 1, <<6, 11_149::16, 1::16>>)
    end

    test "a silent read goes unanswered, and the unit's other reads are answered",
         %{meters: meters} do
      faults = %Faults{silent_reads: MapSet.new([{1, 11_149}])}
      assert :silent = Protocol.respond(meters, faults, 1, <<3, 11_149::16, 2::16>>)

      assert {:reply, <<3, 2, _::16>>} =
               Protocol.respond(meters, faults, 1, <<3, 11_150::16, 1::16>>)
    end

    test "a refused read gets its exception, and the unit's other reads are answered",
         %{meters: meters} do
      faults = %Faults{refused_reads: %{{1, 11_149} => 4}}
      assert {:reply, <<0x83, 4>>} = Protocol.respond(meters, faults, 1, <<3, 11_149::16, 2::16>>)

      assert {:reply, <<3, 2, _::16>>} =
               Protocol.respond(meters, faults, 1, <<3, 11_150::16, 1::16>>)
    end

    test "a refused span gets its exception, and other reads from its address are answered",
         %{meters: meters} do
      faults = %Faults{refused_spans: %{{1, 11_149, 2} => 11}}

      assert {:reply, <<0x83, 11>>} =
               Protocol.respond(meters, faults, 1, <<3, 11_149::16, 2::16>>)

      assert {:reply, <<3, 2, _::16>>} =
               Protocol.respond(meters, faults, 1, <<3, 11_149::16, 1::16>>)
    end

    test "no meter at a unit id stays silent", %{meters: meters} do
      assert :silent = Protocol.respond(meters, %Faults{}, 2, <<3, 11_149::16, 2::16>>)
    end

    test "no meter at a unit id behind a gateway is exception 0B", %{meters: meters} do
      assert {:reply, <<0x83, 0x0B>>} =
               Protocol.respond(meters, %Faults{}, 2, <<3, 11_149::16, 2::16>>, :gateway_error)
    end

    test "a gateway still answers for the meters it has", %{meters: meters} do
      assert {:reply, <<3, 4, _::binary>>} =
               Protocol.respond(meters, %Faults{}, 1, <<3, 11_149::16, 2::16>>, :gateway_error)
    end

    test "a gateway's two-byte reply is 0B alone under its mapped unit byte, and other units are answered",
         %{meters: meters} do
      faults = %Faults{two_byte_replies: %{1 => 7}}

      assert {:reply_as, 7, <<0x0B>>} =
               Protocol.respond(meters, faults, 1, <<3, 11_149::16, 2::16>>)

      assert {:reply, <<3, 4, _::binary>>} =
               Protocol.respond(
                 meters,
                 %{faults | two_byte_replies: %{2 => 1}},
                 1,
                 <<3, 11_149::16, 2::16>>
               )
    end

    test "a selector write is echoed, with the meter that now holds it", %{meters: meters} do
      assert {:write, <<16, 900::16, 1::16>>, meter} =
               Protocol.respond(meters, %Faults{}, 1, <<16, 900::16, 1::16, 2, 4::16>>)

      assert {:ok, [4]} = Meter.read(meter, :holding, 900, 1)
    end

    test "a write the meter refuses is its exception, and a multi-register 16 is 03",
         %{meters: meters} do
      assert {:reply, <<0x90, 2>>} =
               Protocol.respond(meters, %Faults{}, 1, <<16, 5001::16, 1::16, 2, 0::16>>)

      assert {:reply, <<0x90, 3>>} =
               Protocol.respond(meters, %Faults{}, 1, <<16, 900::16, 2::16, 4, 0::32>>)
    end

    test "busy endpoint is exception 06", %{meters: meters} do
      assert {:reply, <<0x83, 6>>} =
               Protocol.respond(meters, %Faults{busy: true}, 1, <<3, 11_149::16, 2::16>>)
    end
  end

  describe "encode_response/4" do
    test "noise goes before an RTU response and not a TCP one" do
      faults = %Faults{noise: <<0xFF, 0>>}
      request = %{transaction_id: 7, unit_id: 1, pdu: <<>>}
      clean = Protocol.encode_response(:rtu_over_tcp, %Faults{}, request, <<0x83, 2>>)

      assert Protocol.encode_response(:rtu_over_tcp, faults, request, <<0x83, 2>>) ==
               <<0xFF, 0>> <> clean

      assert Protocol.encode_response(:tcp, faults, request, <<0x83, 2>>) ==
               Protocol.encode_response(:tcp, %Faults{}, request, <<0x83, 2>>)
    end
  end

  describe "decode_request/2" do
    test "RTU requests are rejected on bad CRC" do
      assert {:error, :bad_crc} =
               Protocol.decode_request(:rtu_over_tcp, <<1, 3, 0, 0, 0, 2, 0, 0>>)
    end

    test "an RTU function 16 request is taken whole, with its data" do
      pdu = <<16, 900::16, 1::16, 2, 4::16>>
      # A request frames as a reply does in RTU: unit, PDU, CRC.
      request = %{transaction_id: 0, unit_id: 1, pdu: <<>>}
      frame = Protocol.encode_response(:rtu_over_tcp, %Faults{}, request, pdu)
      assert :incomplete = Protocol.decode_request(:rtu_over_tcp, binary_part(frame, 0, 10))

      assert {:ok, %{unit_id: 1, pdu: ^pdu}, <<0xAA>>} =
               Protocol.decode_request(:rtu_over_tcp, frame <> <<0xAA>>)
    end
  end
end
