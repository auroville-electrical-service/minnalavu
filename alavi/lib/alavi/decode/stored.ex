defmodule Alavi.Decode.Stored do
  @moduledoc """
  The decode of what a copy reads, under a profile's `meter_clock` and
  `stored` sections (`Alavi.Profile.Stored`), as
  `contract/fixtures/stored-decode.v1.json` pins it. Words are in
  register-address order, as read from the meter. Pure.

  A stamp is the meter's own local time, with no zone, never corrected. A
  value is decoded as `Alavi.Decode` decodes a float register. A quantity
  whose mask bit is clear is unsupported, whatever its words; a NaN or an
  infinity where the mask supports one, or where there is no mask, is
  `not_finite`. Neither is an entry.
  """

  alias Alavi.Decode
  alias Alavi.Profile.Stored

  @type words :: [0..0xFFFF]
  @type error :: :wrong_word_count | :zero_interval | :interval_not_dividing_a_day

  @typedoc "What one history or snapshot entry holds."
  @type block :: %{
          meter_time: NaiveDateTime.t(),
          entries: [{String.t(), Decimal.t()}],
          unsupported: [String.t()],
          not_finite: [String.t()]
        }

  @typedoc """
  One load-survey parameter of one day: each interval ended by the meter's
  clock, by its start; `not_ended` counts the rest, which are not read.
  """
  @type day :: %{
          meter_time: NaiveDateTime.t(),
          interval_s: pos_integer(),
          entries: [{NaiveDateTime.t(), Decimal.t()}],
          not_finite: [NaiveDateTime.t()],
          not_ended: non_neg_integer()
        }

  @day_minutes 1440
  @widths %{u16: 1, u32: 2, u64: 4}

  # contract: test/alavi/decode/stored_test.exs "stored-decode.v1.json"
  @spec stamp(Stored.stamp(), words()) :: {:ok, NaiveDateTime.t()} | {:error, :wrong_word_count}
  def stamp(%{word_order: order, epoch: epoch}, words) do
    with {:ok, seconds} <- Decode.words(:u32, order, 0, words),
         do: {:ok, NaiveDateTime.add(epoch, Decimal.to_integer(seconds))}
  end

  # contract: test/alavi/decode/stored_test.exs "stored-decode.v1.json"
  @spec mask(Stored.mask(), words()) :: {:ok, non_neg_integer()} | {:error, :wrong_word_count}
  def mask(%{type: type, word_order: order}, words) do
    if length(words) == @widths[type] do
      ordered = if order == :low_first, do: Enum.reverse(words), else: words
      {:ok, Enum.reduce(ordered, 0, &(&2 * 0x10000 + &1))}
    else
      {:error, :wrong_word_count}
    end
  end

  @doc "Whether bit `n` of `mask` is set."
  @spec set?(non_neg_integer(), 0..63) :: boolean()
  def set?(mask, n), do: Bitwise.band(Bitwise.bsr(mask, n), 1) == 1

  # contract: test/alavi/decode/stored_test.exs "stored-decode.v1.json"
  @doc "`mask` is the block's mask words, nil when the profile has no mask."
  @spec block(Stored.block(), words(), words() | nil, %{String.t() => words()}) ::
          {:ok, block()} | {:error, :wrong_word_count}
  def block(%{} = block, stamp_words, mask_words, registers) do
    with {:ok, at} <- stamp(block.stamp, stamp_words),
         {:ok, mask} <- block_mask(block.mask, mask_words),
         {:ok, decoded} <- decode_all(block.registers, mask, registers) do
      {:ok, Map.put(decoded, :meter_time, at)}
    end
  end

  # contract: test/alavi/decode/stored_test.exs "stored-decode.v1.json"
  @doc "The interval register's minutes, which must divide a day."
  @spec interval(words()) :: {:ok, pos_integer()} | {:error, error()}
  def interval([0]), do: {:error, :zero_interval}
  def interval([minutes]) when rem(@day_minutes, minutes) == 0, do: {:ok, minutes}
  def interval([_minutes]), do: {:error, :interval_not_dividing_a_day}
  def interval(_words), do: {:error, :wrong_word_count}

  # contract: test/alavi/decode/stored_test.exs "stored-decode.v1.json"
  @doc "A day's values, two words each, from its first interval."
  @spec values(Stored.survey(), words()) ::
          {:ok, [Decimal.t() | :not_finite]} | {:error, :wrong_word_count}
  def values(%{values: %{word_order: order}}, words) when rem(length(words), 2) == 0,
    do: {:ok, words |> Enum.chunk_every(2) |> Enum.map(&value(order, &1))}

  def values(_survey, _words), do: {:error, :wrong_word_count}

  @doc """
  How many of a day's `minutes` intervals from `at` have ended by the meter's
  `clock`, which are the ones to read: every one for a day past (`clock`
  nil). An Elite 500 refuses a read past the interval in progress.
  """
  @spec ended(NaiveDateTime.t(), pos_integer(), NaiveDateTime.t() | nil) :: non_neg_integer()
  def ended(_at, minutes, nil), do: div(@day_minutes, minutes)

  def ended(at, minutes, clock) do
    whole = clock |> NaiveDateTime.diff(at) |> max(0) |> div(minutes * 60)
    min(whole, div(@day_minutes, minutes))
  end

  # contract: test/alavi/decode/stored_test.exs "stored-decode.v1.json"
  @doc """
  One parameter's day. `clock` is the meter clock's words, read on the day
  being copied, or nil for a day past. `values` holds the intervals `ended/3`
  counts, each an entry; the day's others are `not_ended`.
  """
  @spec day(Stored.survey(), %{
          stamp: words(),
          interval: words(),
          values: words(),
          clock: {Stored.stamp(), words()} | nil
        }) :: {:ok, day()} | {:error, error()}
  def day(survey, %{stamp: stamp_words, interval: interval_words} = read) do
    with {:ok, at} <- stamp(survey.stamp, stamp_words),
         {:ok, minutes} <- interval(interval_words),
         {:ok, clock} <- clock(read.clock),
         {:ok, values} <- values(survey, read.values),
         :ok <- count(values, ended(at, minutes, clock)) do
      {:ok, intervals(at, minutes * 60, values, div(@day_minutes, minutes))}
    end
  end

  defp clock(nil), do: {:ok, nil}
  defp clock({stamp, words}), do: stamp(stamp, words)

  defp count(values, n), do: if(length(values) == n, do: :ok, else: {:error, :wrong_word_count})

  defp intervals(at, step, values, of) do
    timed =
      values
      |> Enum.with_index()
      |> Enum.map(fn {v, i} -> {NaiveDateTime.add(at, i * step), v} end)

    %{
      meter_time: at,
      interval_s: step,
      entries: for({start, %Decimal{} = v} <- timed, do: {start, v}),
      not_finite: for({start, :not_finite} <- timed, do: start),
      not_ended: of - length(values)
    }
  end

  defp block_mask(nil, nil), do: {:ok, nil}
  defp block_mask(%{} = mask, words) when is_list(words), do: mask(mask, words)
  defp block_mask(_mask, _words), do: {:error, :wrong_word_count}

  defp decode_all(registers, mask, words) do
    Enum.reduce_while(Enum.reverse(registers), {:ok, empty()}, fn register, {:ok, acc} ->
      case decode_one(register, mask, Map.fetch!(words, register.key)) do
        {:ok, kind, item} -> {:cont, {:ok, Map.update!(acc, kind, &[item | &1])}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp empty, do: %{entries: [], unsupported: [], not_finite: []}

  defp decode_one(%{key: key, mask_bit: bit} = register, mask, words) do
    if supported?(mask, bit), do: decoded(register, words), else: {:ok, :unsupported, key}
  end

  defp supported?(nil, _bit), do: true
  defp supported?(mask, bit), do: set?(mask, bit)

  defp decoded(%{key: key, word_order: order}, words) do
    case value(order, words) do
      %Decimal{} = v -> {:ok, :entries, {key, v}}
      :not_finite -> {:ok, :not_finite, key}
      :wrong_word_count -> {:error, :wrong_word_count}
    end
  end

  defp value(order, words) do
    case Decode.words(:f32, order, nil, words) do
      {:ok, v} -> v
      {:error, reason} -> reason
    end
  end
end
