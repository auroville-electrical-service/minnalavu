defmodule Alavi.TestSink do
  @moduledoc """
  A sink that sends each call's events to a process: a meter's readings and
  missed reads as `{:recorded, events}`, a firmware read as `{:firmware, read}`,
  a poller's latency days as `{:latency, days}`.
  """

  @behaviour Alavi.Sink

  @impl true
  def record(pid, [%Alavi.LatencyDay{} | _] = days) do
    send(pid, {:latency, days})
    :ok
  end

  @impl true
  def record(pid, [%Alavi.FirmwareRead{} = read]) do
    send(pid, {:firmware, read})
    :ok
  end

  def record(pid, events) do
    send(pid, {:recorded, events})
    :ok
  end
end
