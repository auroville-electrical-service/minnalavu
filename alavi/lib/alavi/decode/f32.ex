defmodule Alavi.Decode.F32 do
  @moduledoc """
  The shortest decimal that names an f32's bits: the fewest significant digits
  that parse back, at 32 bits and rounding half to even, to the same bits, and
  of those the nearest the exact value, a tie going to the even last digit.
  Found in exact integer arithmetic: an f32 is never widened to f64 first, as
  `Decimal.from_float/1` would.
  """

  import Bitwise

  # Every finite f32 is a whole multiple of 2^-149, so every value and every
  # midpoint between neighbours is a whole multiple of 2^-150. Below, a value is
  # held as that multiple: an integer over @denominator.
  @denominator 2 ** 150

  # contract: test/alavi/decode_test.exs "value/2"
  @doc "`bits` are a finite, positive, non-zero f32's."
  @spec shortest(1..0x7F7FFFFF) :: Decimal.t()
  def shortest(bits) do
    x = 2 * whole(bits)
    bounds = {whole(bits - 1) + whole(bits), whole(bits) + whole(bits + 1), rem(bits, 2) == 0}
    e = exponent10(x, bits)

    Enum.find_value(1..9, &digits(&1, e, x, bounds)) ||
      raise "no 9-digit decimal names f32 #{Integer.to_string(bits, 16)}"
  end

  # The f32 with these bits times 2^149. One past the largest finite f32 gives
  # 2^128, the bound its rounding interval is taken from.
  defp whole(bits) when bits >>> 23 == 0, do: bits
  defp whole(bits), do: ((bits &&& 0x7FFFFF) ||| 0x800000) <<< ((bits >>> 23) - 1)

  # A neighbour can name the bits only where the interval is lopsided (at a
  # power of two), so the nearest is tried first, then each side.
  defp digits(n, e, x, {low, high, closed}) do
    scale = e - n + 1
    nearest = nearest(x, scale)

    Enum.find_value([nearest, nearest - 1, nearest + 1], fn k ->
      if inside?(compare(k, scale, low), compare(k, scale, high), closed),
        do: 1 |> Decimal.new(k, scale) |> Decimal.normalize()
    end)
  end

  defp inside?(:gt, :lt, _closed), do: true
  defp inside?(:eq, :lt, closed), do: closed
  defp inside?(:gt, :eq, closed), do: closed
  defp inside?(_low, _high, _closed), do: false

  # The e with 10^e <= x < 10^(e + 1), near the float's own log10.
  defp exponent10(x, bits) do
    <<f::float-32>> = <<bits::32>>
    guess = f |> :math.log10() |> floor()

    Enum.find((guess - 2)..(guess + 2), fn e ->
      compare(1, e, x) != :gt and compare(1, e + 1, x) == :gt
    end)
  end

  # x / @denominator / 10^scale, rounded half to even.
  defp nearest(x, scale) do
    {num, den} =
      if scale >= 0, do: {x, @denominator * 10 ** scale}, else: {x * 10 ** -scale, @denominator}

    q = div(num, den)

    case compare_integers(2 * rem(num, den), den) do
      :gt -> q + 1
      :eq -> q + rem(q, 2)
      :lt -> q
    end
  end

  # k * 10^scale against y / @denominator.
  defp compare(k, scale, y) when scale >= 0,
    do: compare_integers(k * 10 ** scale * @denominator, y)

  defp compare(k, scale, y), do: compare_integers(k * @denominator, y * 10 ** -scale)

  defp compare_integers(a, b) when a > b, do: :gt
  defp compare_integers(a, b) when a < b, do: :lt
  defp compare_integers(_a, _b), do: :eq
end
