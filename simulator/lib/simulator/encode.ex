defmodule Simulator.Encode do
  @moduledoc """
  A value to the register words a meter would hold, in address order.

  Integer types store value × 10^decimals, which must come out whole (else it
  raises); float types store the nearest float.
  """

  # contract: test/simulator/encode_test.exs "words/2"
  @spec words(map(), Decimal.t()) :: [0..0xFFFF]
  def words(%{type: type, word_order: order, decimals: decimals}, value) do
    binary = encode(type, value, decimals)
    words = for <<word::16 <- binary>>, do: word
    if order == :low_first, do: Enum.reverse(words), else: words
  end

  defp encode(:f32, value, _decimals), do: <<Decimal.to_float(value)::float-32>>
  defp encode(:f64, value, _decimals), do: <<Decimal.to_float(value)::float-64>>
  defp encode(type, value, decimals), do: integer(type, scaled(value, decimals))

  defp integer(:u16, n) when n in 0..0xFFFF, do: <<n::unsigned-16>>
  defp integer(:i16, n) when n in -0x8000..0x7FFF, do: <<n::signed-16>>
  defp integer(:u32, n) when n in 0..0xFFFFFFFF, do: <<n::unsigned-32>>
  defp integer(:i32, n) when n in -0x80000000..0x7FFFFFFF, do: <<n::signed-32>>
  defp integer(:u64, n) when n >= 0 and n < 0x10000000000000000, do: <<n::unsigned-64>>

  defp scaled(value, decimals) do
    scaled = Decimal.mult(value, Decimal.new(1, 1, decimals))

    if Decimal.integer?(scaled),
      do: Decimal.to_integer(scaled),
      else: raise(ArgumentError, "#{value} has more than #{decimals} decimals")
  end
end
