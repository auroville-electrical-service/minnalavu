defmodule Alavi.TestSink do
  @moduledoc "A sink that sends each meter's events to a process: `{:recorded, events}`."

  @behaviour Alavi.Sink

  @impl true
  def record(pid, events) do
    send(pid, {:recorded, events})
    :ok
  end
end
