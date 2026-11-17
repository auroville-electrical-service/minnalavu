defmodule Alavi.LocalTime do
  @moduledoc """
  The collector's local wall clock, from a UTC instant, by the operating
  system's own zone (`:calendar.universal_time_to_local_time/1`), so it
  needs no time-zone database: what the copy window and the poll slots are
  set in.
  """

  # contract: test/alavi/local_time_test.exs "of/1"
  @doc "The local wall-clock time at the UTC instant `utc`, to the millisecond."
  @spec of(DateTime.t()) :: NaiveDateTime.t()
  def of(%DateTime{} = utc) do
    naive = DateTime.to_naive(utc)
    second = NaiveDateTime.truncate(naive, :second)
    ms = NaiveDateTime.diff(naive, second, :millisecond)

    second
    |> NaiveDateTime.to_erl()
    |> :calendar.universal_time_to_local_time()
    |> NaiveDateTime.from_erl!({0, 3})
    |> NaiveDateTime.add(ms, :millisecond)
  end

  # contract: test/alavi/local_time_test.exs "iso8601/2"
  @doc """
  The local time `at`, to the second, with the offset from UTC that holds at
  the UTC instant `now` (`+05:30`): a time near `now` as a reader on site
  sees it.
  """
  @spec iso8601(NaiveDateTime.t(), DateTime.t()) :: String.t()
  def iso8601(%NaiveDateTime{} = at, %DateTime{} = now) do
    utc = now |> DateTime.to_naive() |> NaiveDateTime.truncate(:second)
    local = now |> of() |> NaiveDateTime.truncate(:second)
    offset = div(NaiveDateTime.diff(local, utc), 60)

    NaiveDateTime.to_iso8601(NaiveDateTime.truncate(at, :second)) <> offset(offset)
  end

  defp offset(minutes) do
    sign = if minutes < 0, do: "-", else: "+"
    hours = minutes |> abs() |> div(60) |> pad()
    "#{sign}#{hours}:#{minutes |> abs() |> rem(60) |> pad()}"
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
end
