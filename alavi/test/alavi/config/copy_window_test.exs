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
end
