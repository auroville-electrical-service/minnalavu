defmodule Alavi.TestSink do
  @moduledoc """
  A sink that sends each call's events to a process: a meter's readings and
  missed reads as `{:recorded, events}`, a firmware read as `{:firmware, read}`,
  a poller's latency days as `{:latency, days}`, a meter-clock read as
  `{:meter_clock, read}`, one copied entry's stored entries as
  `{:stored, entries}`, and a fill's result as `{:fill_result, result}`.

  First it takes the events the way the collector does: through the buffer's
  codec and back unchanged, then each to its wire form and to JSON. An event the
  collector could not send raises in the process that recorded it.
  """

  @behaviour Alavi.Sink

  alias Alavi.Buffer.Codec

  @impl true
  def record(pid, events) do
    sendable!(events)
    send(pid, message(events))
    :ok
  end

  defp message([%Alavi.LatencyDay{} | _] = days), do: {:latency, days}
  defp message([%Alavi.FirmwareRead{} = read]), do: {:firmware, read}
  defp message([%Alavi.MeterClockRead{} = read]), do: {:meter_clock, read}
  defp message([%Alavi.FillResult{} = result]), do: {:fill_result, result}
  defp message([%Alavi.StoredEntry{} | _] = entries), do: {:stored, entries}
  defp message(events), do: {:recorded, events}

  defp sendable!(events) do
    segment =
      Codec.header(<<0::128>>, %{source: :unsynced, last_sync_at: nil}) <> Codec.record(events)

    case Codec.parse(segment) do
      {:ok, %{records: [^events]}} ->
        :ok

      parsed ->
        raise ArgumentError,
              "the buffer does not read back #{inspect(events)}: #{inspect(parsed)}"
    end

    Enum.each(events, fn %kind{} = event -> event |> kind.to_wire() |> JSON.encode!() end)
  end
end
