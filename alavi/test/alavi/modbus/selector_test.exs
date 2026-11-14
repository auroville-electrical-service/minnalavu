defmodule Alavi.Modbus.SelectorTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Alavi.Modbus.Selector

  # The whole allowlist, written out: a change to any address, function code,
  # range or settle time must change this table too.
  @allowlist [
    {"elite_440", :history, 520, 6, :through_available, 0, "elite_440-a"},
    {"elite_440", :snapshot, 700, 6, :below_available, 0, "elite_440-a"},
    {"elite_440", :load_survey_parameter, 800, 6, :supported_bit, 0, "elite_440-a"},
    {"elite_440", :load_survey_day, 801, 6, :below_available, 0, "elite_440-a"},
    {"elite_500", :history, 900, 16, :through_available, 0, "elite_500-a"},
    {"elite_500", :snapshot, 1500, 16, :below_available, 0, "elite_500-a"},
    {"elite_500", :load_survey_day, 5002, 16, :below_available, 100, "elite_500-a"},
    {"elite_500", :load_survey_parameter, 5003, 16, :supported_bit, 100, "elite_500-a"}
  ]

  @names [:history, :snapshot, :load_survey_day, :load_survey_parameter]

  describe "allowlist/0" do
    test "is exactly the pinned table" do
      entries =
        for e <- Selector.allowlist(),
            do: {e.model, e.name, e.address, e.function_code, e.range, e.settle_ms, e.source}

      assert entries == @allowlist
    end

    test "the 500's load-survey configuration below its day selector is not on it" do
      # DLSuppSIPWidth and DLLoggerType, registers 45001 and 45002.
      addresses = Enum.map(Selector.allowlist(), & &1.address)
      refute 5000 in addresses
      refute 5001 in addresses
    end
  end

  describe "request/4" do
    test "each model writes with its own function code, one register" do
      assert {:ok, w440} = Selector.request("elite_440", :history, 3, 6)
      assert Selector.bytes(w440) == <<6, 520::16, 3::16>>
      assert {:ok, w500} = Selector.request("elite_500", :history, 3, 6)
      assert Selector.bytes(w500) == <<16, 900::16, 1::16, 2, 3::16>>
    end

    test "a history may be 0 (live) through the count available" do
      assert {:ok, _} = Selector.request("elite_440", :history, 0, 6)
      assert {:ok, _} = Selector.request("elite_440", :history, 6, 6)
      assert {:error, :out_of_range} = Selector.request("elite_440", :history, 7, 6)
    end

    test "a snapshot or load-survey day is below the count available" do
      assert {:ok, _} = Selector.request("elite_500", :snapshot, 51, 52)
      assert {:error, :out_of_range} = Selector.request("elite_500", :snapshot, 52, 52)
      assert {:error, :out_of_range} = Selector.request("elite_440", :load_survey_day, 0, 0)
    end

    test "a load-survey parameter must be supported by the meter's mask" do
      mask = 0x08880303
      assert {:ok, _} = Selector.request("elite_440", :load_survey_parameter, 27, mask)

      assert {:error, :out_of_range} =
               Selector.request("elite_440", :load_survey_parameter, 2, mask)

      assert {:error, :out_of_range} =
               Selector.request("elite_500", :load_survey_parameter, 0, -1)
    end

    test "an unknown model or selector is refused, and so is a value outside a word" do
      assert {:error, :not_allowed} = Selector.request("elite_300", :history, 0, 6)
      assert {:error, :not_allowed} = Selector.request("elite_440", :clock, 0, 6)
      assert {:error, :out_of_range} = Selector.request("elite_440", :history, -1, 6)
      assert {:error, :out_of_range} = Selector.request("elite_440", :history, 0x10000, 0x10000)
    end

    property "from any input, a request is one allowlisted register, in range, of a write's exact shape" do
      check all model <- member_of(["elite_440", "elite_500", "elite_300"]),
                name <- member_of([:clock | @names]),
                value <- integer(-2..0x10002),
                bound <- one_of([integer(-2..100), integer(-1..0xFFFFFFFF)]),
                max_runs: 2_000 do
        case Selector.request(model, name, value, bound) do
          {:ok, request} -> assert_allowed(model, name, value, bound, request)
          {:error, _} -> :ok
        end
      end
    end
  end

  describe "parse_reply/2" do
    test "an exact echo is :ok" do
      {:ok, w440} = Selector.request("elite_440", :snapshot, 0, 1)
      assert :ok = Selector.parse_reply(w440, <<6, 700::16, 0::16>>)
      {:ok, w500} = Selector.request("elite_500", :snapshot, 9, 52)
      assert :ok = Selector.parse_reply(w500, <<16, 1500::16, 1::16>>)
    end

    test "an echo of another address, value or count is a mismatch" do
      {:ok, w440} = Selector.request("elite_440", :history, 2, 6)
      assert {:error, :echo_mismatch} = Selector.parse_reply(w440, <<6, 521::16, 2::16>>)
      assert {:error, :echo_mismatch} = Selector.parse_reply(w440, <<6, 520::16, 3::16>>)
      assert {:error, :echo_mismatch} = Selector.parse_reply(w440, <<16, 520::16, 1::16>>)
      {:ok, w500} = Selector.request("elite_500", :history, 2, 6)
      assert {:error, :echo_mismatch} = Selector.parse_reply(w500, <<16, 900::16, 2::16>>)
      assert {:error, :echo_mismatch} = Selector.parse_reply(w500, <<16, 900::16>>)
    end

    test "an exception reply is the exception" do
      {:ok, w440} = Selector.request("elite_440", :history, 2, 6)
      assert {:error, {:exception, 2}} = Selector.parse_reply(w440, <<0x86, 2>>)
      assert {:error, :echo_mismatch} = Selector.parse_reply(w440, <<0x90, 2>>)
    end
  end

  defp assert_allowed(model, name, value, bound, request) do
    assert [{^model, ^name, address, fc, range, settle_ms, _source}] =
             Enum.filter(@allowlist, &match?({^model, ^name, _, _, _, _, _}, &1))

    assert Selector.settle_ms(request) == settle_ms
    assert value in 0..0xFFFF
    assert in_range?(range, value, bound)

    case fc do
      6 -> assert Selector.bytes(request) == <<6, address::16, value::16>>
      16 -> assert Selector.bytes(request) == <<16, address::16, 1::16, 2, value::16>>
    end
  end

  defp in_range?(:through_available, value, available), do: value <= available
  defp in_range?(:below_available, value, available), do: value < available

  defp in_range?(:supported_bit, value, mask),
    do: mask >= 0 and Integer.digits(mask, 2) |> Enum.reverse() |> Enum.at(value) == 1
end
