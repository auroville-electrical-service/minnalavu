defmodule Alavi.Sink do
  @moduledoc """
  Where the poller hands over what it read: `{module, arg}`, called as
  `module.record(arg, events)` once per meter per round. A sink must not return
  `:ok` before the events are kept, and it runs in the poller's process, so it
  delays the endpoint's next read.
  """

  alias Alavi.{MissedRead, Reading}

  @type event :: Reading.t() | MissedRead.t()
  @type t :: {module(), term()}

  @callback record(arg :: term(), [event(), ...]) :: :ok | {:error, term()}

  # contract: test/alavi/sink_test.exs "record/2"
  @spec record(t(), [event(), ...]) :: :ok | {:error, term()}
  def record({module, arg}, events) do
    case module.record(arg, events) do
      :ok -> :ok
      {:error, _reason} = error -> error
    end
  end
end
