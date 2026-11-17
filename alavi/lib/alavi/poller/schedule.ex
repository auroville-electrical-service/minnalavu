defmodule Alavi.Poller.Schedule do
  @moduledoc """
  What an endpoint's poller does next, from its queue of jobs, the clocks and
  when each meter is due: run the next step of a queued job, start a poll
  round over the meters now due, or wait until the first is due.

  A meter's rounds fall on slots of the collector's local wall clock
  (`Alavi.LocalTime`): its interval, which divides a day, counted from local
  midnight. A slot is numbered by its local date and its index from that
  midnight, as one integer that orders them (`slot/2`). A meter is due when
  the slot now is later than the last one a round was started in, so slots
  passed by a clock set forward, or by a long round, come to one round, and
  after a clock set back nothing is due until a later slot. A meter whose
  round missed reads from it for want of an answer (`after_round/3`), is
  due again a retry interval after that round ended, on the monotonic clock,
  or at its next slot if that comes first, until a round reads it whole.
  """

  # contract: test/alavi/poller/schedule_test.exs "next/4"
  # A meter due again while its round is unfinished starts no round: the
  # round under way runs to its end first. A meter overdue by its interval
  # puts poll rounds ahead of reads on demand, so that a stream of reads
  # cannot stop the rounds that billing is read from. An owed restore comes
  # before everything, once it is ready; until then the rest goes on. A copy
  # comes after everything else, a step at a time.

  alias Alavi.Config.Meter
  alias Alavi.Poller.Job

  @typedoc """
  The clocks a decision is made at: monotonic milliseconds, and the
  collector's local wall-clock time.
  """
  @type now :: %{monotonic: integer(), local: NaiveDateTime.t()}

  @typedoc """
  A meter's last slot a round started in, and when it is due again for a
  retry (monotonic milliseconds), nil when it is not on one.
  """
  @type meter_due :: %{slot: integer(), retry_at: integer() | nil}

  @typedoc "When each meter, by unit ID, is due."
  @type due :: %{(unit_id :: 1..247) => meter_due()}

  @typedoc """
  `{:step, job, rest}`: run the next step of `job`, `rest` the queue without
  it. `{:start, job}`: queue this new poll round. `{:wait, ms}`: nothing is
  due for `ms` milliseconds.
  """
  @type decision :: {:step, Job.t(), [Job.t()]} | {:start, Job.t()} | {:wait, pos_integer()}

  # Job kinds, highest priority first, while no meter is overdue by its
  # interval, and once one is. A round not yet started ranks as its kind,
  # below any queued job of the same rank.
  @ranks [:restore, :read_on_demand, :poll_round, :copy]
  @overdue_ranks [:restore, :poll_round, :read_on_demand, :copy]

  @reads_max 8

  # The local wall clock's start, from which slots are counted.
  @epoch ~N[0000-01-01 00:00:00]

  @doc "With no `meters`, no round starts: the queue drains (a poller retiring)."
  @spec next([Job.t()], now(), due(), [Meter.t()]) :: decision()
  def next(queue, now, due, meters) do
    ranks = ranks(meters, due, now)

    ready? = Enum.any?(queue, &Job.ready?(&1, now.monotonic))

    case {Enum.filter(meters, &due?(&1, due[&1.unit_id], now)), ready?} do
      {[], false} ->
        {:wait, wait(queue, due, meters, now)}

      {[], true} ->
        step(queue, now.monotonic, ranks)

      {due_now, ready?} ->
        chosen(queue, ready?, Job.poll_round(due_now, now.monotonic), now, ranks)
    end
  end

  # contract: test/alavi/poller/schedule_test.exs "slot/2"
  @doc """
  The slot of `interval_ms` that the local time `local` falls in: the local
  date's slots from midnight, numbered on from the day before's.
  """
  @spec slot(NaiveDateTime.t(), pos_integer()) :: integer()
  def slot(%NaiveDateTime{} = local, interval_ms),
    do: div(NaiveDateTime.diff(local, @epoch, :millisecond), interval_ms)

  # contract: test/alavi/poller/schedule_test.exs "start/2"
  @doc "When `meters` are due on a poller's start: every one at once, for the slot it is in."
  @spec start([Meter.t()], now()) :: due()
  def start(meters, now),
    do:
      Map.new(meters, &{&1.unit_id, %{slot: slot(now.local, &1.interval_ms) - 1, retry_at: nil}})

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

  # contract: test/alavi/poller/schedule_test.exs "retired/1"
  @doc "`queue` without the poll rounds not yet begun: a retiring poller's next round boundary."
  @spec retired([Job.t()]) :: [Job.t()]
  def retired(queue), do: Enum.reject(queue, &(&1.kind == :poll_round and &1.events == []))

  # contract: test/alavi/poller/schedule_test.exs "reconnected/2"
  @doc "`queue` once the endpoint is connected again: a restore held for want of a connection is ready."
  @spec reconnected([Job.t()], integer()) :: [Job.t()]
  def reconnected(queue, now) do
    Enum.map(queue, fn
      %Job{kind: :restore, held: :connection} = job -> %{job | not_before: now, held: :backoff}
      job -> job
    end)
  end

  # contract: test/alavi/poller/schedule_test.exs "started/3"
  @doc "When each meter is due once `round` has started at `now`: not again in the slot it is in."
  @spec started(due(), Job.t(), now()) :: due()
  def started(due, %Job{kind: :poll_round, meters: meters}, now) do
    Enum.reduce(meters, due, fn %Meter{unit_id: unit} = meter, due ->
      Map.update!(due, unit, &%{&1 | slot: max(&1.slot, slot(now.local, meter.interval_ms))})
    end)
  end

  # contract: test/alavi/poller/schedule_test.exs "after_round/3"
  @doc """
  When each meter is due once `round` has ended, at `ended` (monotonic
  milliseconds): a meter the round did not reach (`Alavi.Poller.Job.unreached/2`)
  a retry interval later, or at its next slot; the others at their next slot.
  """
  @spec after_round(due(), Job.t(), integer()) :: due()
  def after_round(due, %Job{kind: :poll_round, meters: meters, unreached: unreached}, ended) do
    Enum.reduce(meters, due, fn %Meter{unit_id: unit} = meter, due ->
      retry_at = if unit in unreached, do: ended + meter.retry_ms
      Map.update!(due, unit, &%{&1 | retry_at: retry_at})
    end)
  end

  # contract: test/alavi/poller/schedule_test.exs "due_at/3"
  @doc """
  When `meter` is next due, in local time at `now`, and whether on a retry: a
  time past for a meter due now, from when it became due.
  """
  @spec due_at(meter_due(), Meter.t(), now()) :: %{at: NaiveDateTime.t(), retrying: boolean()}
  def due_at(%{retry_at: nil} = d, meter, _now),
    do: %{at: slot_start(d.slot + 1, meter), retrying: false}

  def due_at(d, meter, now) do
    retry = NaiveDateTime.add(now.local, d.retry_at - now.monotonic, :millisecond)
    slot = slot_start(d.slot + 1, meter)
    %{at: Enum.min([retry, slot], NaiveDateTime), retrying: true}
  end

  defp slot_start(slot, meter),
    do: NaiveDateTime.add(@epoch, slot * meter.interval_ms, :millisecond)

  defp due?(meter, d, now),
    do: slot(now.local, meter.interval_ms) > d.slot or retry_due?(d, now.monotonic, 0)

  # Due for at least its interval: the whole slot after its last has passed,
  # or its retry was due an interval ago.
  defp overdue?(meter, d, now),
    do:
      slot(now.local, meter.interval_ms) > d.slot + 1 or
        retry_due?(d, now.monotonic, meter.interval_ms)

  defp retry_due?(%{retry_at: nil}, _monotonic, _late), do: false
  defp retry_due?(%{retry_at: at}, monotonic, late), do: at + late <= monotonic

  defp ranks(meters, due, now) do
    if Enum.any?(meters, &overdue?(&1, due[&1.unit_id], now)),
      do: @overdue_ranks,
      else: @ranks
  end

  defp wait(queue, due, meters, now) do
    held = for %Job{not_before: at} <- queue, at != nil, do: at - now.monotonic
    Enum.min(Enum.flat_map(meters, &until_due(&1, due[&1.unit_id], now)) ++ held)
  end

  # Milliseconds until a meter not yet due is: its next slot, and its retry.
  defp until_due(meter, d, now) do
    slot = NaiveDateTime.diff(slot_start(d.slot + 1, meter), now.local, :millisecond)
    retry = if d.retry_at, do: [d.retry_at - now.monotonic], else: []
    [max(slot, 1) | retry]
  end

  defp chosen(_queue, false, round, _now, _ranks), do: {:start, round}

  defp chosen(queue, true, round, now, ranks) do
    {:step, top, _rest} = step = step(queue, now.monotonic, ranks)
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
