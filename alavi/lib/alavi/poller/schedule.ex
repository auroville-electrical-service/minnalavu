defmodule Alavi.Poller.Schedule do
  @moduledoc """
  What an endpoint's poller does next, from its queue of jobs, the clock and
  when each meter is due: run the next step of a queued job, start a poll
  round over the meters now due, or wait until the first is due.
  """

  # contract: test/alavi/poller/schedule_test.exs "next/4"
  # A meter due again while its round is unfinished starts no round: the
  # round under way runs to its end first.

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

  # Job kinds, highest priority first. A round not yet started ranks as its
  # kind, below any queued job of the same rank.
  @ranks [:read_on_demand, :poll_round]

  @spec next([Job.t()], integer(), due(), [Meter.t(), ...]) :: decision()
  def next(queue, now, due, meters) do
    case {Enum.filter(meters, &(due[&1.unit_id] <= now)), queue} do
      {[], []} -> {:wait, (due |> Map.values() |> Enum.min()) - now}
      {[], queue} -> step(queue)
      {due_now, queue} -> chosen(queue, Job.poll_round(due_now, now))
    end
  end

  # contract: test/alavi/poller/schedule_test.exs "after_round/2"
  @doc "When each meter is due once `round` is done: its meters an interval after it started."
  @spec after_round(due(), Job.t()) :: due()
  def after_round(due, %Job{kind: :poll_round, meters: meters, started: started}),
    do: Map.merge(due, Map.new(meters, &{&1.unit_id, started + &1.interval_ms}))

  defp chosen([], round), do: {:start, round}

  defp chosen(queue, round) do
    {:step, top, _rest} = step = step(queue)
    if rank(round) < rank(top), do: {:start, round}, else: step
  end

  # The first queued job of the highest rank, and the queue without it.
  defp step(queue) do
    {_job, index} = queue |> Enum.with_index() |> Enum.min_by(fn {job, _i} -> rank(job) end)
    {before, [job | rest]} = Enum.split(queue, index)
    {:step, job, before ++ rest}
  end

  defp rank(%Job{kind: kind}), do: Enum.find_index(@ranks, &(&1 == kind))
end
