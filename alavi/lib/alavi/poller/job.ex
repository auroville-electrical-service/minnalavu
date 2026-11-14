defmodule Alavi.Poller.Job do
  @moduledoc """
  A job on one endpoint, and how far it has got: the poller runs one step of
  it per message. A poll round's steps are one per meter (its identity and
  registers), then one per meter identified in the round (its firmware
  names), in the order the meters were read.
  """

  # contract: test/alavi/poller/job_test.exs "poll_round/2"

  alias Alavi.Config.Meter
  alias Alavi.{MissedRead, Reading}
  alias Alavi.Profile.Identity

  @enforce_keys [:kind, :meters, :started, :meters_left, :names_left, :events, :down]
  defstruct @enforce_keys

  @type kind :: :poll_round
  @type event :: Reading.t() | MissedRead.t()
  @typedoc """
  A meter whose identity was read, what it reported, and why its register
  reads stopped (`nil` when they did not), for its names step.
  """
  @type identified :: {Meter.t(), Identity.observed(), term()}
  @type step :: {:meter, Meter.t()} | {:names, identified()}

  @type t :: %__MODULE__{
          kind: kind(),
          meters: [Meter.t()],
          started: integer(),
          meters_left: [Meter.t()],
          names_left: [identified()],
          events: [[event()]],
          down: term()
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
      down: nil
    }
  end

  @spec next(t()) :: step() | :done
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
        names_left: job.names_left ++ List.wrap(identified)
    }
  end

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
