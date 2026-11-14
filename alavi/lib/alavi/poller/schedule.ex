defmodule Alavi.Poller.Schedule do
  @moduledoc """
  What an endpoint's poller does next, from its queue of jobs, the clock and
  when each meter is due: run the next step of a queued job, start a poll
  round over the meters now due, or wait until the first is due.
  """

  # contract: test/alavi/poller/schedule_test.exs "next/4"
  # A meter due again while its round is unfinished starts no round: the
  # round under way runs to its end first. A meter overdue by its interval
  # puts poll rounds ahead of reads on demand, so that a stream of reads
  # cannot stop the rounds that billing is read from. An owed restore comes
  # before everything, once it is ready; until then the rest goes on.

  alias Alavi.Config.Meter
  alias Alavi.Poller.Job

  @typedoc "When each meter, by unit ID, is next due (monotonic milliseconds)."
  @type due :: %{(unit_id :: 1..247) => integer()}

  @typedoc """
  `{:step, job, rest}`: run the next step of `job`, `rest` the queue without
  it. `{:start, job}`: queue this new poll round. `{:wait, ms}`: nothing is
  due for `ms` milliseconds.
  """
  @type decision :: {:step, Job.t(), [Job.t()]} | {:start, Job.t()} | {:wait, pos_integer()}

  # Job kinds, highest priority first, while no meter is overdue by its
  # interval, and once one is. A round not yet started ranks as its kind,
  # below any queued job of the same rank.
  @ranks [:restore, :read_on_demand, :poll_round]
  @overdue_ranks [:restore, :poll_round, :read_on_demand]

  @reads_max 8

  @spec next([Job.t()], integer(), due(), [Meter.t(), ...]) :: decision()
  def next(queue, now, due, meters) do
    ranks = ranks(meters, due, now)

    ready? = Enum.any?(queue, &Job.ready?(&1, now))

    case {Enum.filter(meters, &(due[&1.unit_id] <= now)), ready?} do
      {[], false} -> {:wait, wait(queue, due, now)}
      {[], true} -> step(queue, now, ranks)
      {due_now, ready?} -> chosen(queue, ready?, Job.poll_round(due_now, now), now, ranks)
    end
  end

  # contract: test/alavi/poller/schedule_test.exs "queue_read/2"
  @doc """
  `queue` with the read on demand `read` at its end, or `:busy` when the
  endpoint already has #{@reads_max} reads on demand queued or under way.
  """
  @spec queue_read([Job.t()], Job.t()) :: {:ok, [Job.t()]} | {:error, :busy}
  def queue_read(queue, %Job{kind: :read_on_demand} = read) do
    if Enum.count(queue, &(&1.kind == :read_on_demand)) < @reads_max,
      do: {:ok, queue ++ [read]},
      else: {:error, :busy}
  end

  # contract: test/alavi/poller/schedule_test.exs "restore/3"
  @doc "`queue` with one restore, held back until `at`, in place of any it held."
  @spec restore([Job.t()], integer(), Job.held()) :: [Job.t()]
  def restore(queue, at, held),
    do: [Job.restore(at, held) | Enum.reject(queue, &(&1.kind == :restore))]

  # contract: test/alavi/poller/schedule_test.exs "reconnected/2"
  @doc "`queue` once the endpoint is connected again: a restore held for want of a connection is ready."
  @spec reconnected([Job.t()], integer()) :: [Job.t()]
  def reconnected(queue, now) do
    Enum.map(queue, fn
      %Job{kind: :restore, held: :connection} = job -> %{job | not_before: now, held: :backoff}
      job -> job
    end)
  end

  # contract: test/alavi/poller/schedule_test.exs "after_round/2"
  @doc "When each meter is due once `round` is done: its meters an interval after it started."
  @spec after_round(due(), Job.t()) :: due()
  def after_round(due, %Job{kind: :poll_round, meters: meters, started: started}),
    do: Map.merge(due, Map.new(meters, &{&1.unit_id, started + &1.interval_ms}))

  defp ranks(meters, due, now) do
    if Enum.any?(meters, &(due[&1.unit_id] + &1.interval_ms <= now)),
      do: @overdue_ranks,
      else: @ranks
  end

  defp wait(queue, due, now) do
    held = for %Job{not_before: at} <- queue, at != nil, do: at
    Enum.min(Map.values(due) ++ held) - now
  end

  defp chosen(_queue, false, round, _now, _ranks), do: {:start, round}

  defp chosen(queue, true, round, now, ranks) do
    {:step, top, _rest} = step = step(queue, now, ranks)
    if rank(round, ranks) < rank(top, ranks), do: {:start, round}, else: step
  end

  # The first ready job of the highest rank, and the queue without it.
  defp step(queue, now, ranks) do
    {_job, index} =
      queue
      |> Enum.with_index()
      |> Enum.filter(fn {job, _i} -> Job.ready?(job, now) end)
      |> Enum.min_by(fn {job, _i} -> rank(job, ranks) end)

    {before, [job | rest]} = Enum.split(queue, index)
    {:step, job, before ++ rest}
  end

  defp rank(%Job{kind: kind}, ranks), do: Enum.find_index(ranks, &(&1 == kind))
end
