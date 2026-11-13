defmodule Simulator.EncodeTest do
  use ExUnit.Case, async: true

  alias Simulator.Encode

  describe "words/2" do
    test "orders words by the spec" do
      spec = %{type: :u32, word_order: :low_first, decimals: 2}
      assert Encode.words(spec, Decimal.new("1234.56")) == [0xE240, 0x0001]

      assert Encode.words(%{spec | word_order: :high_first}, Decimal.new("1234.56")) == [
               0x0001,
               0xE240
             ]
    end

    test "raises when the value has more decimals than the spec" do
      spec = %{type: :u32, word_order: :high_first, decimals: 2}
      assert_raise ArgumentError, fn -> Encode.words(spec, Decimal.new("1.234")) end
    end
  end
end
