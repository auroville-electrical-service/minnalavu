defmodule Alavi.Poller.ScheduleTest do
  use ExUnit.Case, async: true

  import Alavi.PollerCase

  alias Alavi.Poller.{Job, Schedule}

  # Units 1 and 2 every 60 s, unit 3 every 10 s.
  defp meters do
    config =
      config!([
        endpoint(502, "tcp", [
          meter(1, "elite_440"),
          meter(2, "elite_440"),
          meter(3, "elite_440", %{"interval_ms" => 10_000})
        ])
      ])

    hd(config.endpoints).meters
  end

  defp seen(unit), do: %{serial: "SIM-#{unit}", product_code: "ELITE440-445"}

  describe "next/4" do
    test "with nothing queued, a round starts over every meter due, in config order" do
      [m1, _m2, m3] = ms = meters()
      due = %{1 => 100, 2 => 101, 3 => 50}

      assert {:start, %Job{kind: :poll_round, meters: [^m1, ^m3], started: 100}} =
               Schedule.next([], 100, due, ms)
    end

    test "with nothing queued and nothing due, it waits until the first meter is due" do
      due = %{1 => 500, 2 => 300, 3 => 900}
      assert Schedule.next([], 100, due, meters()) == {:wait, 200}
    end

    test "a meter due exactly now is due" do
      [_m1, m2, _m3] = ms = meters()
      assert {:start, %Job{meters: [^m2]}} = Schedule.next([], 7, %{1 => 8, 2 => 7, 3 => 8}, ms)
    end

    test "a queued round is stepped, not restarted, while nothing is due" do
      [m1, m2, _m3] = ms = meters()
      round = [m1, m2] |> Job.poll_round(0) |> Job.polled([:read], {m1, seen(1), nil})

      assert Schedule.next([round], 10, %{1 => 60_000, 2 => 60_000, 3 => 10_000}, ms) ==
               {:step, round, []}
    end

    test "no new round starts while one is unfinished, even with its meters due again" do
      [m1, m2, m3] = ms = meters()
      round = Job.poll_round([m1, m2, m3], 0)

      assert Schedule.next([round], 20_000, %{1 => 0, 2 => 0, 3 => 0}, ms) ==
               {:step, round, []}
    end

    test "the first queued round of the highest rank runs, and the rest stay in order" do
      [m1, m2, m3] = ms = meters()
      a = Job.poll_round([m1], 0)
      b = Job.poll_round([m2], 1)
      c = Job.poll_round([m3], 2)

      assert Schedule.next([a, b, c], 5, %{1 => 9, 2 => 9, 3 => 9}, ms) == {:step, a, [b, c]}
    end

    test "a read on demand runs before a round under way, and before a round due" do
      [m1, m2, m3] = ms = meters()
      round = [m1, m2] |> Job.poll_round(0) |> Job.polled([:read], {m1, seen(1), nil})
      {:ok, read} = Job.read_on_demand(ms, [3], 5, {self(), make_ref()})
      due = %{1 => 60_000, 2 => 60_000, 3 => 0}

      assert Schedule.next([round, read], 5, due, ms) == {:step, read, [round]}
      assert Schedule.next([read], 5, due, ms) == {:step, read, []}
      assert {:start, %Job{kind: :poll_round, meters: [^m3]}} = Schedule.next([], 5, due, ms)
    end
  end

  describe "after_round/2" do
    test "each meter of the round is next due an interval after the round started" do
      [m1, _m2, m3] = meters()
      due = %{1 => 0, 2 => 40, 3 => 0}
      round = Job.poll_round([m1, m3], 5)

      assert Schedule.after_round(due, round) == %{1 => 60_005, 2 => 40, 3 => 10_005}
    end

    test "a round that overran its interval leaves its meters due at once" do
      [m1, m2, m3] = ms = meters()
      due = Schedule.after_round(%{1 => 0, 2 => 0, 3 => 0}, Job.poll_round([m1, m2, m3], 0))

      assert {:start, %Job{meters: [^m3], started: 12_000}} =
               Schedule.next([], 12_000, due, ms)
    end
  end
end
