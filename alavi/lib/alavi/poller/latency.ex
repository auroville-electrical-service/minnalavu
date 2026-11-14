defmodule Alavi.Poller.Latency do
  @days 7
  # Upper bounds in ms, about 25 % apart: a percentile reads as "at most this".
  @bounds [1, 2, 3, 4, 5, 6, 8, 10, 12, 15, 20, 25, 30, 40, 50, 60, 80, 100, 120, 150] ++
            [200, 250, 300, 400, 500, 600, 800, 1_000, 1_200, 1_500, 2_000, 2_500, 3_000] ++
            [4_000, 5_000, 6_000, 8_000, 10_000, 12_000, 15_000, 20_000, 30_000, 60_000]
  @over length(@bounds)

  @moduledoc """
  One meter's request latency, per UTC day, for the last #{@days} days. Pure:
  the poller holds one per meter. A day is a histogram with fixed log-scale
  buckets, so its size does not grow with the requests; percentiles are read
  from it as the upper bound of the bucket they fall in, never above the
  exact maximum.

  An answer is a sample: a reply with words, or a meter's own exception. A
  timeout is censored, so counted and never a sample; so is exception 0B, the
  gateway's word that the meter did not answer in time. Anything else (0A,
  a closed socket, a reply that could not be parsed) is neither.
  """

  alias Alavi.Modbus.Client

  @enforce_keys [:days]
  defstruct @enforce_keys

  @typedoc "An index into the bounds; one past the last for an answer above it."
  @type bucket :: non_neg_integer()

  @type day :: %{
          answered: non_neg_integer(),
          retries: non_neg_integer(),
          timeouts: non_neg_integer(),
          max: non_neg_integer() | nil,
          buckets: %{bucket() => pos_integer()}
        }

  @typedoc "Newest day first; each day is at most #{@days - 1} days older than the newest."
  @type t :: %__MODULE__{days: [{Date.t(), day()}]}

  @typedoc """
  Over the days kept, from `since`. `retries`: answers on a retry, not the
  first attempt. Percentiles and `max` in ms, nil while nothing answered.
  """
  @type summary :: %{
          since: Date.t(),
          answered: non_neg_integer(),
          retries: non_neg_integer(),
          timeouts: non_neg_integer(),
          p50: non_neg_integer() | nil,
          p90: non_neg_integer() | nil,
          p99: non_neg_integer() | nil,
          max: non_neg_integer() | nil
        }

  @spec new() :: t()
  def new, do: %__MODULE__{days: []}

  # contract: test/alavi/poller/latency_test.exs "record/5"
  @doc """
  One request's outcome on `date`, at attempt `attempt` (from 1), `ms` after
  it was sent. A date before the newest day kept counts in the newest.
  """
  @spec record(t(), Date.t(), pos_integer(), non_neg_integer(), :ok | Client.error()) :: t()
  def record(%__MODULE__{} = latency, date, attempt, ms, outcome) do
    case kind(outcome) do
      :answered -> on(latency, date, &answered(&1, attempt, ms))
      :timeout -> on(latency, date, &%{&1 | timeouts: &1.timeouts + 1})
      :neither -> latency
    end
  end

  # contract: test/alavi/poller/latency_test.exs "summary/1"
  @doc "Over every day kept; nil before anything was recorded."
  @spec summary(t()) :: summary() | nil
  def summary(%__MODULE__{days: []}), do: nil

  def summary(%__MODULE__{days: days}) do
    {since, _day} = List.last(days)
    days |> Enum.map(&elem(&1, 1)) |> Enum.reduce(&merge/2) |> summarised(since)
  end

  # contract: test/alavi/poller/latency_test.exs "line/2"
  @doc """
  One day's figures as a log line, with its bucket counts (`bound:count`,
  `>60000` above the last), so that days can be merged from the log; nil if
  that day is not kept.
  """
  @spec line(t(), Date.t()) :: String.t() | nil
  def line(%__MODULE__{days: days}, date) do
    case List.keyfind(days, date, 0) do
      nil -> nil
      {^date, day} -> format(summarised(day, date), day.buckets)
    end
  end

  defp kind(:ok), do: :answered
  defp kind(:timeout), do: :timeout
  defp kind({:exception, 0x0B}), do: :timeout
  defp kind({:exception, 0x0A}), do: :neither
  defp kind({:exception, _code}), do: :answered
  defp kind(_other), do: :neither

  defp on(%__MODULE__{days: [{newest, day} | rest] = days} = latency, date, change) do
    if Date.after?(date, newest),
      do: %{latency | days: [{date, change.(empty())} | Enum.filter(days, &kept?(&1, date))]},
      else: %{latency | days: [{newest, change.(day)} | rest]}
  end

  defp on(%__MODULE__{days: []} = latency, date, change),
    do: %{latency | days: [{date, change.(empty())}]}

  defp kept?({date, _day}, newest), do: Date.diff(newest, date) < @days

  defp empty, do: %{answered: 0, retries: 0, timeouts: 0, max: nil, buckets: %{}}

  defp answered(day, attempt, ms) do
    %{
      day
      | answered: day.answered + 1,
        retries: day.retries + if(attempt > 1, do: 1, else: 0),
        max: max(day.max || 0, ms),
        buckets: Map.update(day.buckets, bucket(ms), 1, &(&1 + 1))
    }
  end

  defp bucket(ms), do: Enum.find_index(@bounds, &(ms <= &1)) || @over

  defp merge(a, b) do
    %{
      answered: a.answered + b.answered,
      retries: a.retries + b.retries,
      timeouts: a.timeouts + b.timeouts,
      max: larger(a.max, b.max),
      buckets: Map.merge(a.buckets, b.buckets, fn _bucket, m, n -> m + n end)
    }
  end

  defp larger(nil, b), do: b
  defp larger(a, nil), do: a
  defp larger(a, b), do: max(a, b)

  defp summarised(day, since) do
    at = fn p -> percentile(day, p) end

    %{
      since: since,
      answered: day.answered,
      retries: day.retries,
      timeouts: day.timeouts,
      p50: at.(50),
      p90: at.(90),
      p99: at.(99),
      max: day.max
    }
  end

  defp percentile(%{answered: 0}, _p), do: nil

  # Nearest rank: the smallest bucket holding at least p % of the answers.
  defp percentile(%{answered: n, max: max, buckets: buckets}, p) do
    rank = div(n * p + 99, 100)

    buckets
    |> Enum.sort()
    |> Enum.reduce_while(0, fn {bucket, count}, seen ->
      if seen + count >= rank, do: {:halt, {:at, bucket}}, else: {:cont, seen + count}
    end)
    |> then(fn {:at, bucket} -> at_most(bucket, max) end)
  end

  defp at_most(@over, max), do: max
  defp at_most(bucket, max), do: min(Enum.at(@bounds, bucket), max)

  defp format(s, buckets) do
    "#{s.since} UTC: #{s.answered} answered (#{s.retries} on a retry), " <>
      "#{s.timeouts} timed out; p50 #{ms(s.p50)}, p90 #{ms(s.p90)}, p99 #{ms(s.p99)}, " <>
      "max #{ms(s.max)}; buckets #{buckets(buckets)}"
  end

  defp ms(nil), do: "none"
  defp ms(ms), do: "#{ms} ms"

  defp buckets(buckets) when buckets == %{}, do: "none"

  defp buckets(buckets),
    do: buckets |> Enum.sort() |> Enum.map_join(" ", fn {b, n} -> "#{label(b)}:#{n}" end)

  defp label(@over), do: ">#{List.last(@bounds)}"
  defp label(bucket), do: Enum.at(@bounds, bucket)
end
