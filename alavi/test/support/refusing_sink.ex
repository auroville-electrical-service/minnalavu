defmodule Alavi.RefusingSink do
  @moduledoc "A sink that sends each meter's events to a process, then refuses them as a full buffer would."

  @behaviour Alavi.Sink

  @impl true
  def record(pid, events) do
    send(pid, {:recorded, events})
    {:error, :full}
  end
end
