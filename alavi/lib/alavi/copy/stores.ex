defmodule Alavi.Copy.Stores do
  @moduledoc """
  What a copy reads from each store, as pure data from a profile's stored
  section (`Alavi.Profile.Stored`): which slots hold entries, newest first;
  which entries are due, from what a scan of their stamps found; and which
  reads cover an entry, each a run of registers the profile names, so that no
  read spans a register it does not.

  A store's entries are copied oldest first, so that the progress kept after
  each (`Alavi.Copy.Progress`) never passes one not yet copied. A load-survey
  day is due one parameter at a time; the current day is copied each night
  for its intervals ended so far, and its progress kept only once the meter's
  clock has ended the whole day.
  """

  alias Alavi.Decode.Stored, as: Decode
  alias Alavi.Profile.Stored

  @type store :: :history | :snapshot | :load_survey
  @type slot :: 0..0xFFFF
  @typedoc "A run of consecutive holding registers: PDU address and count."
  @type run :: {0..0xFFFF, 1..125}
  @typedoc """
  An entry due: a history or snapshot's slot and stamp, or a load-survey
  day's with one parameter's number, and whether it is the day's last.
  """
  @type item ::
          {slot(), NaiveDateTime.t()}
          | {slot(), NaiveDateTime.t(), Stored.parameter(), last :: boolean()}

  @stores [:history, :snapshot, :load_survey]
  @max_words 125

  @doc "The stores a copy visits, in order."
  @spec all() :: [store(), ...]
  def all, do: @stores

  # contract: test/alavi/copy/stores_test.exs "slots/2"
  @doc """
  The slots of a store holding `available` entries, newest first: histories
  from 1 (0 shows live values), snapshots and load-survey days from 0 (today).
  """
  @spec slots(store(), non_neg_integer()) :: [slot()]
  def slots(:history, available), do: Enum.to_list(1..available//1)
  def slots(_store, available), do: Enum.to_list(0..(available - 1)//1)

  # contract: test/alavi/copy/stores_test.exs "scanned/4"
  @doc """
  A scan newest first, with `stamp` read at `slot`: `:more` while each stamp
  is newer than `last`, the last copied (nil: none yet), and `:found` once one
  is not, or the slots run out.
  """
  @spec scanned([{slot(), NaiveDateTime.t()}], slot(), NaiveDateTime.t(), NaiveDateTime.t() | nil) ::
          {:more | :found, [{slot(), NaiveDateTime.t()}]}
  def scanned(found, slot, stamp, last) do
    if last == nil or NaiveDateTime.after?(stamp, last),
      do: {:more, found ++ [{slot, stamp}]},
      else: {:found, found}
  end

  # contract: test/alavi/copy/stores_test.exs "due/2"
  @doc """
  The entries due, oldest first, from a scan's `found` (newest first): for
  the load survey, one item per day and parameter, in `parameters`' order.
  """
  @spec due([{slot(), NaiveDateTime.t()}], [Stored.parameter()] | nil) :: [item()]
  def due(found, nil), do: Enum.reverse(found)

  def due(found, parameters) do
    last = List.last(parameters)

    for {slot, stamp} <- Enum.reverse(found),
        p <- parameters,
        do: {slot, stamp, p, p == last}
  end

  # contract: test/alavi/copy/stores_test.exs "parameters/2"
  @doc "The load-survey parameters the profile names and the meter's mask supports."
  @spec parameters(Stored.survey(), non_neg_integer()) :: [Stored.parameter()]
  def parameters(%{parameters: parameters}, mask),
    do: Enum.filter(parameters, &Decode.set?(mask, &1.number))

  # contract: test/alavi/copy/stores_test.exs "runs/1"
  @doc """
  The reads of these `{address, words}` spans: adjoining spans merged, and
  none longer than #{@max_words} words.
  """
  @spec runs([{0..0xFFFF, pos_integer()}]) :: [run()]
  def runs(spans) do
    spans
    |> Enum.sort()
    |> Enum.chunk_while(nil, &merge/2, &{:cont, &1, nil})
    |> Enum.flat_map(&split/1)
  end

  defp merge(span, nil), do: {:cont, span}
  defp merge({a, n}, {start, count}) when a == start + count, do: {:cont, {start, count + n}}
  defp merge(span, run), do: {:cont, run, span}

  defp split({address, count}) when count <= @max_words, do: [{address, count}]

  defp split({address, count}),
    do: [{address, @max_words} | split({address + @max_words, count - @max_words})]

  # contract: test/alavi/copy/stores_test.exs "runs/1"
  @doc "The spans of one history or snapshot entry: its stamp, its mask, and each register."
  @spec block_spans(Stored.block()) :: [{0..0xFFFF, pos_integer()}]
  def block_spans(%{stamp: stamp, mask: mask, registers: registers}) do
    [{stamp.address, 2}] ++
      mask_span(mask) ++ Enum.map(registers, &{&1.address, 2})
  end

  defp mask_span(nil), do: []
  defp mask_span(%{address: address, type: type}), do: [{address, mask_words(type)}]

  @doc "The words a mask of this type takes."
  @spec mask_words(:u16 | :u32 | :u64) :: 1 | 2 | 4
  def mask_words(:u16), do: 1
  def mask_words(:u32), do: 2
  def mask_words(:u64), do: 4

  # contract: test/alavi/copy/stores_test.exs "runs/1"
  @doc "The reads of a load-survey day's first `intervals` intervals: `per_request` intervals each."
  @spec value_runs(Stored.survey(), non_neg_integer()) :: [run()]
  def value_runs(%{values: %{address: address, per_request: per}}, intervals) do
    for first <- 0..(intervals - 1)//per,
        do: {address + 2 * first, 2 * min(per, intervals - first)}
  end

  @doc "The words of `runs`, read as `words`, by address."
  @spec at([{run(), [0..0xFFFF]}]) :: %{(0..0xFFFF) => 0..0xFFFF}
  def at(read) do
    for {{address, _count}, words} <- read,
        {word, i} <- Enum.with_index(words),
        into: %{},
        do: {address + i, word}
  end

  @doc "`count` words from `address`, out of `at/1`'s map."
  @spec words(%{(0..0xFFFF) => 0..0xFFFF}, 0..0xFFFF, non_neg_integer()) :: [0..0xFFFF]
  def words(by_address, address, count),
    do: for(a <- address..(address + count - 1)//1, do: Map.fetch!(by_address, a))
end
