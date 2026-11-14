defmodule Alavi.RefusingSink do
  @moduledoc """
  A sink that sends each call's events to a process, as `Alavi.TestSink`
  does, then refuses them as a full buffer would.
  """

  @behaviour Alavi.Sink

  @impl true
  def record(pid, events) do
    :ok = Alavi.TestSink.record(pid, events)
    {:error, :full}
  end
end
