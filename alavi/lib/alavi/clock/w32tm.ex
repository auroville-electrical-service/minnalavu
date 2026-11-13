defmodule Alavi.Clock.W32tm do
  @moduledoc """
  Reads the clock status out of the report of `w32tm /query /status /verbose`.
  Pure: `Alavi.Clock.Windows` runs the command.

  The time since the last good sync is used, not `Last Successful Sync Time`,
  which is a local time with no zone. The labels are those of an English
  Windows; anything else is `{:error, :unrecognised}`, never a guess.
  """

  alias Alavi.Clock

  @host ~r/^[A-Za-z0-9.:\-\[\]]+(,0x[0-9A-Fa-f]+)?$/
  @since ~r/^(\d+)(?:\.(\d{1,7}))?s$/

  # contract: test/alavi/clock/w32tm_test.exs "parse/2"
  @spec parse(String.t(), DateTime.t()) :: {:ok, Clock.status()} | {:error, :unrecognised}
  def parse(output, now) do
    fields = fields(output)

    with {:ok, leap} <- Map.fetch(fields, "Leap Indicator"),
         true <- Regex.match?(~r/^[0-3]/, leap),
         {:ok, source} <- Map.fetch(fields, "Source"),
         {:ok, status} <- classify(source, leap, fields, now) do
      {:ok, status}
    else
      _ -> {:error, :unrecognised}
    end
  end

  # contract: test/alavi/clock/w32tm_test.exs "settle/2"
  @doc "The last sync time is worked out from the time since, so it wobbles between queries."
  @spec settle(Clock.status(), Clock.status()) :: Clock.status()
  def settle(
        %{source: source, last_sync_at: %DateTime{} = was} = previous,
        %{source: source, last_sync_at: %DateTime{} = at} = new
      ) do
    if abs(DateTime.diff(at, was, :millisecond)) <= 2000, do: previous, else: new
  end

  def settle(_previous, new), do: new

  defp classify("Free-running System Clock", _leap, _fields, _now), do: {:ok, Clock.unsynced()}

  defp classify("Local CMOS Clock", _leap, _fields, _now),
    do: {:ok, %{source: :rtc, last_sync_at: nil}}

  defp classify(source, leap, fields, now) do
    cond do
      not Regex.match?(@host, source) -> :error
      String.starts_with?(leap, "3") -> {:ok, Clock.unsynced()}
      true -> synced(Map.get(fields, "Time since Last Good Sync Time", ""), now)
    end
  end

  defp synced(since, now) do
    case Regex.run(@since, since) do
      [_, seconds] -> {:ok, ntp(now, String.to_integer(seconds) * 1000)}
      [_, seconds, fraction] -> {:ok, ntp(now, millis(seconds, fraction))}
      nil -> :error
    end
  end

  defp millis(seconds, fraction),
    do:
      String.to_integer(seconds) * 1000 +
        (fraction |> String.pad_trailing(3, "0") |> binary_part(0, 3) |> String.to_integer())

  defp ntp(now, ago_ms),
    do: %{
      source: :ntp,
      last_sync_at: now |> DateTime.add(-ago_ms, :millisecond) |> DateTime.truncate(:second)
    }

  # "Label: value" lines, split at the first colon; a value may hold colons.
  defp fields(output) do
    output
    |> String.split(~r/\R/)
    |> Enum.flat_map(fn line ->
      case String.split(line, ":", parts: 2) do
        [label, value] -> [{String.trim(label), String.trim(value)}]
        [_] -> []
      end
    end)
    |> Map.new()
  end
end
