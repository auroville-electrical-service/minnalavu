defmodule Alavi.Poller.Job do
  @moduledoc """
  A job on one endpoint, and how far it has got: the poller runs one step of
  it per message. A poll round's steps are one per meter (its identity and
  registers), then one per meter identified in the round (its firmware
  names), in the order the meters were read.

  A read on demand's steps are one per named meter, the same as a round's
  meter steps, and no names: those are read daily (`Alavi.Poller.Names`), and
  the round that follows reads them when due, so a read on demand asked to
  answer in seconds is not lengthened by them.

  A copy (`copy/2`) runs an `Alavi.Copy.Run` a phase per step: an entry
  copied, a selector session opened or closed, a meter's clock read, so polls
  and reads on demand go between them.

  A restore (`restore/2`) is one step, putting back the selectors a session
  saved (`Alavi.Selectors.Session.restore/3`); while it waits to be retried,
  `not_before` holds it back, and `held` says whether for a connection or
  for its backoff.
  """

  # contract: test/alavi/poller/job_test.exs "poll_round/2"

  alias Alavi.Config.Meter
  alias Alavi.Copy.Run
  alias Alavi.{MissedRead, Reading}
  alias Alavi.Profile.Identity

  @enforce_keys [
    :kind,
    :meters,
    :started,
    :meters_left,
    :names_left,
    :events,
    :down,
    :requester,
    :request_id,
    :not_before,
    :held,
    :copy
  ]
  defstruct @enforce_keys

  @type kind :: :poll_round | :read_on_demand | :restore | :copy
  @type held :: :connection | :backoff
  @typedoc "Who asked for a read on demand, and the reference they are told it by."
  @type requester :: {pid(), reference()}
  @type event :: Reading.t() | MissedRead.t()
  @typedoc """
  A meter whose identity was read, what it reported, and why its register
  reads stopped (`nil` when they did not), for its names step.
  """
  @type identified :: {Meter.t(), Identity.observed(), term()}
  @type step :: {:meter, Meter.t()} | {:names, identified()} | {:copy, Run.t()}

  @type t :: %__MODULE__{
          kind: kind(),
          meters: [Meter.t()],
          started: integer(),
          meters_left: [Meter.t()],
          names_left: [identified()],
          events: [[event()]],
          down: term(),
          requester: requester() | nil,
          request_id: String.t() | nil,
          not_before: integer() | nil,
          held: held() | nil,
          copy: Run.t() | nil
        }

  @doc "A round over `meters`, started at `started` (monotonic milliseconds)."
  @spec poll_round([Meter.t()], integer()) :: t()
  def poll_round(meters, started) do
    %__MODULE__{
      kind: :poll_round,
      meters: meters,
      started: started,
      meters_left: meters,
      names_left: [],
      events: [],
      down: nil,
      requester: nil,
      request_id: nil,
      not_before: nil,
      held: nil,
      copy: nil
    }
  end

  # contract: test/alavi/poller/job_test.exs "copy/2"
  @doc "A copy of the stored entries of `meters`, started at `started` (monotonic milliseconds)."
  @spec copy([Meter.t()], integer()) :: t()
  def copy(meters, started), do: %{poll_round([], started) | kind: :copy, copy: Run.new(meters)}

  @doc "The copy's run after its step."
  @spec copied(t(), Run.t()) :: t()
  def copied(%__MODULE__{kind: :copy} = job, run), do: %{job | copy: run}

  # contract: test/alavi/poller/job_test.exs "restore/2"
  @doc "A restore of an endpoint's owed selectors, not run before `not_before` (monotonic milliseconds)."
  @spec restore(integer(), held()) :: t()
  def restore(not_before, held),
    do: %{poll_round([], not_before) | kind: :restore, not_before: not_before, held: held}

  @doc "Whether the job may run at `now`."
  @spec ready?(t(), integer()) :: boolean()
  def ready?(%__MODULE__{not_before: nil}, _now), do: true
  def ready?(%__MODULE__{not_before: at}, now), do: at <= now

  # contract: test/alavi/poller/job_test.exs "read_on_demand/4"
  @doc """
  A read on demand of the `units` named, from the endpoint's `meters`, in
  their chain order, started at `started` (monotonic milliseconds). Its
  readings and missed reads carry `request_id`.
  """
  @spec read_on_demand([Meter.t()], [1..247], integer(), requester(), String.t() | nil) ::
          {:ok, t()} | {:error, :no_units | {:unknown_units, [term()]}}
  def read_on_demand(meters, units, started, requester, request_id \\ nil)

  def read_on_demand(_meters, [], _started, _requester, _request_id), do: {:error, :no_units}

  def read_on_demand(meters, units, started, requester, request_id) when is_list(units) do
    known = Enum.map(meters, & &1.unit_id)

    case Enum.reject(units, &(&1 in known)) do
      [] ->
        named = Enum.filter(meters, &(&1.unit_id in units))
        job = poll_round(named, started)
        {:ok, %{job | kind: :read_on_demand, requester: requester, request_id: request_id}}

      unknown ->
        {:error, {:unknown_units, Enum.uniq(unknown)}}
    end
  end

  @spec next(t()) :: step() | :done
  def next(%__MODULE__{kind: :copy, copy: run}),
    do: if(Run.done?(run), do: :done, else: {:copy, run})

  def next(%__MODULE__{meters_left: [meter | _]}), do: {:meter, meter}
  def next(%__MODULE__{names_left: [identified | _]}), do: {:names, identified}
  def next(%__MODULE__{}), do: :done

  @doc "The meter step done, with its events, and the meter if it was identified."
  @spec polled(t(), [event()], identified() | nil) :: t()
  def polled(%__MODULE__{meters_left: [_ | rest]} = job, events, identified) do
    %{
      job
      | meters_left: rest,
        events: [events | job.events],
        names_left: job.names_left ++ named(job.kind, identified)
    }
  end

  defp named(:poll_round, identified), do: List.wrap(identified)
  defp named(:read_on_demand, _identified), do: []

  @doc "The names step done."
  @spec named(t()) :: t()
  def named(%__MODULE__{meters_left: [], names_left: [_ | rest]} = job),
    do: %{job | names_left: rest}

  @doc "The endpoint could not be reached: the round's later reads are not tried."
  @spec down(t(), term()) :: t()
  def down(%__MODULE__{} = job, reason), do: %{job | down: reason}

  @doc "Every meter step's events so far, in the order the steps ran."
  @spec events(t()) :: [event()]
  def events(%__MODULE__{events: events}), do: events |> Enum.reverse() |> Enum.concat()
end
