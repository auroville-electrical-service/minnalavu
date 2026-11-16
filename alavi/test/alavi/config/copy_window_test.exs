defmodule Alavi.Config.CopyWindowTest do
  use ExUnit.Case, async: true

  alias Alavi.Config.CopyWindow

  describe "open?/2" do
    test "a window within a day is open from its start up to its end" do
      window = %CopyWindow{start: ~T[02:00:00], end: ~T[03:00:00]}

      assert Enum.map(
               [~T[01:59:59], ~T[02:00:00], ~T[02:59:59.999999], ~T[03:00:00]],
               &CopyWindow.open?(window, &1)
             ) ==
               [false, true, true, false]
    end

    test "a window across midnight is open from its start to midnight and from midnight to its end" do
      window = %CopyWindow{start: ~T[23:30:00], end: ~T[00:30:00]}

      assert Enum.map(
               [
                 ~T[23:29:59],
                 ~T[23:30:00],
                 ~T[00:00:00],
                 ~T[00:29:59],
                 ~T[00:30:00],
                 ~T[12:00:00]
               ],
               &CopyWindow.open?(window, &1)
             ) == [false, true, true, true, false, false]
    end
  end

  describe "opened_at/2" do
    test "an open window opened today at its start, or yesterday when it crossed midnight" do
      day = %CopyWindow{start: ~T[02:00:00], end: ~T[03:00:00]}
      night = %CopyWindow{start: ~T[23:30:00], end: ~T[00:30:00]}

      assert CopyWindow.opened_at(day, ~N[2026-11-16 02:30:00]) == ~N[2026-11-16 02:00:00]
      assert CopyWindow.opened_at(day, ~N[2026-11-16 03:00:00]) == nil
      assert CopyWindow.opened_at(night, ~N[2026-11-16 23:45:00]) == ~N[2026-11-16 23:30:00]
      assert CopyWindow.opened_at(night, ~N[2026-11-17 00:10:00]) == ~N[2026-11-16 23:30:00]
      assert CopyWindow.opened_at(night, ~N[2026-11-17 12:00:00]) == nil
    end

    test "the window next opens at its start today, or tomorrow once that has passed" do
      day = %CopyWindow{start: ~T[02:00:00], end: ~T[03:00:00]}

      assert CopyWindow.next_open(day, ~N[2026-11-16 01:59:59]) == ~N[2026-11-16 02:00:00]
      assert CopyWindow.next_open(day, ~N[2026-11-16 02:00:00]) == ~N[2026-11-17 02:00:00]
      assert CopyWindow.next_open(day, ~N[2026-11-16 12:00:00]) == ~N[2026-11-17 02:00:00]
    end
  end
end
