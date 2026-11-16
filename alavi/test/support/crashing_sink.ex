defmodule Alavi.CrashingSink do
  @moduledoc """
  `Alavi.TestSink`, but the poller crashes once, inside the sink, just after
  the `n`th copied entry's events are kept: as a collector that stops between
  buffering an entry and saving its progress.
  """

  @behaviour Alavi.Sink

  @impl true
  def record({pid, counter, n}, [%Alavi.StoredEntry{} | _] = entries) do
    :ok = Alavi.TestSink.record(pid, entries)
    :counters.add(counter, 1, 1)
    if :counters.get(counter, 1) == n, do: raise("crashed after entry #{n} was kept")
    :ok
  end

  def record({pid, _counter, _n}, events), do: Alavi.TestSink.record(pid, events)
end
