defmodule Alavi.LocalTimeTest do
  use ExUnit.Case, async: true

  alias Alavi.LocalTime

  # The operating system's own conversion, to the second, as a reference.
  defp os_local(utc) do
    utc
    |> DateTime.to_naive()
    |> NaiveDateTime.truncate(:second)
    |> NaiveDateTime.to_erl()
    |> :calendar.universal_time_to_local_time()
    |> NaiveDateTime.from_erl!()
  end

  describe "of/1" do
    test "is the operating system's local time, keeping the milliseconds" do
      utc = ~U[2026-11-17 18:29:59.987Z]
      local = LocalTime.of(utc)

      assert NaiveDateTime.truncate(local, :second) == os_local(utc)
      assert local.microsecond == {987_000, 3}
    end
  end

  describe "iso8601/2" do
    test "a local time, to the second, with the offset that holds now" do
      now = ~U[2026-11-17 06:30:00Z]
      offset_s = NaiveDateTime.diff(os_local(now), DateTime.to_naive(now))
      text = LocalTime.iso8601(~N[2026-11-17 12:00:00.250], now)

      assert "2026-11-17T12:00:00" <> offset = text
      assert offset =~ ~r/^[+-]\d\d:\d\d$/

      {:ok, parsed, ^offset_s} = DateTime.from_iso8601("2026-11-17T12:00:00" <> offset)
      assert parsed == DateTime.add(~U[2026-11-17 12:00:00Z], -offset_s)
    end
  end
end
