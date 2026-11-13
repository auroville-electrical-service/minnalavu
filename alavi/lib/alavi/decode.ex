defmodule Alavi.Decode do
  @moduledoc """
  Words are big-endian within themselves (Modbus); `word_order` says whether the
  most significant word comes first.
  """

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
  defp number(<<f::float-32>>, %Register{type: :f32} = r), do: rounded(f, r)
  defp number(<<f::float-64>>, %Register{type: :f64} = r), do: rounded(f, r)
  # A float pattern does not match NaN or infinity.
  defp number(_binary, %Register{}), do: {:error, :not_finite}

  defp scaled(n, %Register{decimals: d}) when n < 0, do: {:ok, Decimal.new(-1, -n, -d)}
  defp scaled(n, %Register{decimals: d}), do: {:ok, Decimal.new(1, n, -d)}

  # Decimal.round raises past the context's precision, and any two words can be a huge float.
  @float_context %Decimal.Context{precision: 320, rounding: :half_even}

  defp rounded(f, %Register{decimals: d}) do
    Decimal.Context.with(@float_context, fn ->
      {:ok, f |> Decimal.from_float() |> Decimal.round(d, :half_even)}
    end)
  end
end
