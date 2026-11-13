defmodule Alavi.Poller.RawLog do
  @moduledoc """
  The lines a poller logs for the raw bytes of unexpected replies, capped so a
  noisy line cannot flood the disk. Pure: the poller passes in the time and
  logs what comes back.
  """

  alias Alavi.Modbus.Client

  @enforce_keys [:endpoint, :limits, :window_start, :count, :suppressed]
  defstruct @enforce_keys

  @type limits :: %{
          max_frame_bytes: pos_integer(),
          max_lines: pos_integer(),
          window_ms: pos_integer()
        }

  @typedoc "`window_start` is in the poller's monotonic ms, `nil` before the first anomaly."
  @type t :: %__MODULE__{
          endpoint: String.t(),
          limits: limits(),
          window_start: integer() | nil,
          count: non_neg_integer(),
          suppressed: non_neg_integer()
        }

  @spec new(String.t(), limits()) :: t()
  def new(endpoint, limits),
    do: %__MODULE__{
      endpoint: endpoint,
      limits: limits,
      window_start: nil,
      count: 0,
      suppressed: 0
    }

  # contract: test/alavi/poller/raw_log_test.exs "note/3 and flush/2"
  @spec note(t(), [Client.anomaly()], integer()) :: {[String.t()], t()}
  def note(log, anomalies, now) do
    {summary, log} = flush(log, now)
    {lines, log} = Enum.flat_map_reduce(anomalies, open(log, now), &admit/2)
    {summary ++ lines, log}
  end

  # contract: test/alavi/poller/raw_log_test.exs "note/3 and flush/2"
  @spec flush(t(), integer()) :: {[String.t()], t()}
  def flush(%__MODULE__{window_start: start, limits: %{window_ms: ms}} = log, now)
      when start != nil and now - start >= ms do
    {summary(log), %{log | window_start: nil, count: 0, suppressed: 0}}
  end

  def flush(log, _now), do: {[], log}

  defp open(%__MODULE__{window_start: nil} = log, now), do: %{log | window_start: now}
  defp open(log, _now), do: log

  defp admit(anomaly, %__MODULE__{count: count, limits: %{max_lines: max}} = log)
       when count < max,
       do: {[line(log, anomaly)], %{log | count: count + 1}}

  defp admit(_anomaly, log), do: {[], %{log | suppressed: log.suppressed + 1}}

  defp summary(%__MODULE__{suppressed: 0}), do: []

  defp summary(%__MODULE__{limits: limits} = log) do
    window = "#{limits.window_ms} ms"

    [
      "alavi poller #{log.endpoint}: #{log.suppressed} more raw-bytes line(s) suppressed in " <>
        "#{window} (at most #{limits.max_lines} per #{window})"
    ]
  end

  defp line(log, %{kind: :skipped, unit_id: unit, reasons: reasons, bytes: bytes}) do
    why = Enum.map_join(reasons, ", ", &reason/1)

    "alavi poller #{log.endpoint} unit #{unit}: #{byte_size(bytes)} bytes skipped " <>
      "before the reply (#{why}): #{hex(bytes, log.limits.max_frame_bytes)}"
  end

  defp line(log, %{kind: :rejected, unit_id: unit, reason: reason, bytes: bytes}) do
    "alavi poller #{log.endpoint} unit #{unit}: reply rejected (#{inspect(reason)}), " <>
      "#{byte_size(bytes)} bytes: #{hex(bytes, log.limits.max_frame_bytes)}"
  end

  defp reason(:noise), do: "noise"
  defp reason(:bad_crc), do: "bad CRC"
  defp reason(:stale), do: "stale transaction id"

  defp hex(bytes, max) when byte_size(bytes) <= max, do: spaced(bytes)

  defp hex(bytes, max),
    do: "#{spaced(binary_part(bytes, 0, max))} (first #{max} shown)"

  defp spaced(bytes), do: Enum.map_join(:binary.bin_to_list(bytes), " ", &byte/1)

  defp byte(b), do: b |> Integer.to_string(16) |> String.pad_leading(2, "0")
end
