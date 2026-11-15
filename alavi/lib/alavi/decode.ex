defmodule Alavi.Decode do
  @moduledoc """
  Words are big-endian within themselves (Modbus); `word_order` says whether the
  most significant word comes first. An integer register's value is exact, with
  its `decimals` places. A float's is the shortest decimal that, parsed at the
  register's own width, gives back the meter's bits: lossless, so the words are
  recoverable from it, but not the float's exact value (`0.1` for the f32 whose
  value is 0.100000001490116...). Rounding is the reader's business.
  """

  alias Alavi.Decode.F32
  alias Alavi.Profile.Register

  @type error :: :wrong_word_count | :not_finite

  # contract: test/alavi/decode_test.exs "value/2"
  @doc "`words` are in register-address order, as read from the meter."
  @spec value(Register.t(), [0..0xFFFF]) :: {:ok, Decimal.t()} | {:error, error()}
  def value(%Register{} = register, words) do
    if length(words) == Register.word_count(register) do
      register.word_order |> ordered(words) |> to_binary() |> number(register)
    else
      {:error, :wrong_word_count}
    end
  end

  defp ordered(:high_first, words), do: words
  defp ordered(:low_first, words), do: Enum.reverse(words)

  defp to_binary(words), do: for(word <- words, into: <<>>, do: <<word::16>>)

  defp number(<<n::unsigned-16>>, %Register{type: :u16} = r), do: scaled(n, r)
  defp number(<<n::signed-16>>, %Register{type: :i16} = r), do: scaled(n, r)
  defp number(<<n::unsigned-32>>, %Register{type: :u32} = r), do: scaled(n, r)
  defp number(<<n::signed-32>>, %Register{type: :i32} = r), do: scaled(n, r)
  defp number(<<n::unsigned-64>>, %Register{type: :u64} = r), do: scaled(n, r)
  defp number(<<_::float-32>> = b, %Register{type: :f32}), do: {:ok, f32(b)}
  defp number(<<f::float-64>>, %Register{type: :f64}), do: {:ok, f64(f)}
  # A float pattern does not match NaN or infinity.
  defp number(_binary, %Register{}), do: {:error, :not_finite}

  defp scaled(n, %Register{decimals: d}) when n < 0, do: {:ok, Decimal.new(-1, -n, -d)}
  defp scaled(n, %Register{decimals: d}), do: {:ok, Decimal.new(1, n, -d)}

  defp f32(<<sign::1, 0::31>>), do: Decimal.new(sign(sign), 0, 0)
  defp f32(<<sign::1, bits::31>>), do: bits |> F32.shortest() |> signed(sign)

  defp signed(d, 1), do: Decimal.negate(d)
  defp signed(d, 0), do: d

  defp sign(1), do: -1
  defp sign(0), do: 1

  # Erlang's shortest round-trip form of an f64, as Decimal.from_float/1 takes it.
  defp f64(f), do: f |> Decimal.from_float() |> Decimal.normalize()
end
