defmodule Alavi.SntpTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Alavi.Sntp

  @nonce <<0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6, 0x07, 0x18>>

  # 2026-11-01T00:00:08Z in NTP seconds (era 0).
  @seconds 0xEE90FF88

  # A server's reply, built field by field as RFC 4330 §4 lays it out.
  defp reply(fields \\ []) do
    f =
      Map.merge(
        %{
          leap: 0,
          version: 4,
          mode: 4,
          stratum: 2,
          reference_id: 0xC0000283,
          origin: @nonce,
          received: <<@seconds::32, 0x370A70A4::32>>,
          sent: <<@seconds::32, 0x370D5735::32>>,
          extra: <<>>
        },
        Map.new(fields)
      )

    <<f.leap::2, f.version::3, f.mode::3, f.stratum::8, 6::8, -23::signed-8, 0x0000_0123::32,
      0x0000_0456::32, f.reference_id::32, @seconds - 60::32, 0::32, f.origin::binary-8,
      f.received::binary-8, f.sent::binary-8, f.extra::binary>>
  end

  defp parsed!(fields \\ []) do
    {:ok, answer} = Sntp.parse(reply(fields), @nonce)
    answer
  end

  defp utc(ns), do: Sntp.rfc3339(ns)

  describe "request/1" do
    test "48 bytes: no leap warning, version 4, client mode, the nonce as transmit timestamp" do
      request = Sntp.request(@nonce)
      assert byte_size(request) == 48
      assert <<0::2, 4::3, 3::3, 0::312, @nonce::binary>> = request
      assert <<0x23, _::binary>> = request
    end
  end

  describe "parse/2" do
    test "an answer: the server's times, stratum, leap and reference ID as sent" do
      answer = parsed!()
      assert %{stratum: 2, leap: 0, reference_id: 0xC0000283} = answer
      assert utc(answer.received) == "2026-11-01T00:00:08.215003051Z"
      assert utc(answer.sent) == "2026-11-01T00:00:08.215047312Z"
    end

    test "the fraction is truncated to the nanosecond, never rounded up" do
      # 0x370A70A4 is 215003051.795 ns: truncated, ...051.
      assert parsed!().received == 1_793_491_208_215_003_051

      for {fraction, ns} <- [
            {0, 0},
            {1, 0},
            {0x8000_0000, 500_000_000},
            {0xFFFF_FFFF, 999_999_999}
          ] do
        answer = parsed!(received: <<@seconds::32, fraction::32>>)
        assert Integer.mod(answer.received, 1_000_000_000) == ns
      end
    end

    property "every fraction is the greatest nanosecond count not past it" do
      check all fraction <- integer(0..0xFFFF_FFFF) do
        ns =
          Integer.mod(parsed!(received: <<@seconds::32, fraction::32>>).received, 1_000_000_000)

        assert ns * 2 ** 32 <= fraction * 1_000_000_000
        assert (ns + 1) * 2 ** 32 > fraction * 1_000_000_000
      end
    end

    test "seconds with the top bit set are era 0 (1968 to 2036), clear era 1 (2036 to 2104)" do
      for {seconds, expected} <- [
            {0x8000_0000, "1968-01-20T03:14:08.000000000Z"},
            {0xFFFF_FFFF, "2036-02-07T06:28:15.000000000Z"},
            {0x0000_0000, "2036-02-07T06:28:16.000000000Z"},
            {0x7FFF_FFFF, "2104-02-26T09:42:23.000000000Z"}
          ] do
        assert utc(parsed!(received: <<seconds::32, 0::32>>).received) == expected
      end
    end

    test "extension fields or a MAC after the header are ignored" do
      assert parsed!(extra: :binary.copy(<<0xEE>>, 20)) == parsed!()
    end

    test "a leap indicator of 1 or 2 is an answer" do
      assert %{leap: 1} = parsed!(leap: 1)
      assert %{leap: 2} = parsed!(leap: 2)
    end

    test "stratum 0 is a kiss-o'-death, with its code, whatever its leap indicator" do
      rate = 0x52415445

      assert {:error, {:kiss_of_death, ^rate}} =
               Sntp.parse(reply(stratum: 0, reference_id: rate, leap: 3), @nonce)
    end

    test "a reply that is not a usable answer is invalid, and says why" do
      for {fields, why} <- [
            {[mode: 3], "mode 3"},
            {[mode: 5], "mode 5"},
            {[version: 3], "version 3"},
            {[origin: <<0::64>>], "originate"},
            {[leap: 3], "leap indicator 3"},
            {[stratum: 16], "stratum 16"},
            {[sent: <<0::64>>], "transmit timestamp of zero"}
          ] do
        assert {:error, {:invalid, message}} = Sntp.parse(reply(fields), @nonce), inspect(fields)
        assert message =~ why
      end
    end

    test "fewer than 48 bytes is invalid" do
      assert {:error, {:invalid, "47 bytes" <> _}} =
               Sntp.parse(binary_part(reply(), 0, 47), @nonce)

      assert {:error, {:invalid, _}} = Sntp.parse(<<>>, @nonce)
    end

    property "any bytes parse to an answer or a refusal, never a crash" do
      check all packet <- binary() do
        assert match?({:ok, _}, Sntp.parse(packet, @nonce)) or
                 match?(
                   {:error, {kind, _}} when kind in [:invalid, :kiss_of_death],
                   Sntp.parse(packet, @nonce)
                 )
      end
    end
  end

  describe "rfc3339/1" do
    test "UTC, always with nine fraction digits, before 1970 too" do
      assert Sntp.rfc3339(0) == "1970-01-01T00:00:00.000000000Z"
      assert Sntp.rfc3339(1_793_491_208_000_000_007) == "2026-11-01T00:00:08.000000007Z"
      assert Sntp.rfc3339(-1) == "1969-12-31T23:59:59.999999999Z"
    end
  end
end
