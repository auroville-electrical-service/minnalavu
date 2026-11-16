defmodule Alavi.TestSink do
  @moduledoc """
  A sink that sends each call's events to a process: a meter's readings and
  missed reads as `{:recorded, events}`, a firmware read as `{:firmware, read}`,
  a poller's latency days as `{:latency, days}`, a meter-clock read as
  `{:meter_clock, read}`, and one copied entry's stored entries as
  `{:stored, entries}`.
  """

  @behaviour Alavi.Sink

  @impl true
  def record(pid, [%Alavi.LatencyDay{} | _] = days) do
    send(pid, {:latency, days})
    :ok
  end

  def record(pid, [%Alavi.FirmwareRead{} = read]) do
    send(pid, {:firmware, read})
    :ok
  end

  def record(pid, [%Alavi.MeterClockRead{} = read]) do
    send(pid, {:meter_clock, read})
    :ok
  end

  def record(pid, [%Alavi.StoredEntry{} | _] = entries) do
    send(pid, {:stored, entries})
    :ok
  end

  def record(pid, events) do
    send(pid, {:recorded, events})
    :ok
  end
end
