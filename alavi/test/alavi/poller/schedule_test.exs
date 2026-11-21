defmodule Alavi.Poller.ScheduleTest do
  use ExUnit.Case, async: true

  import Alavi.PollerCase

  alias Alavi.Poller.{Job, Schedule}

  # Units 1 and 2 every 60 s, unit 3 every 10 s.
  defp meters do
    config =
      config!([
        endpoint(
          502,
          "tcp",
          [
            meter(1, "elite_440"),
            meter(2, "elite_440"),
            meter(3, "elite_440", %{"interval_ms" => 10_000})
          ],
          %{"interval_ms" => 60_000}
        )
      ])

    hd(config.endpoints).meters
  end

  defp seen(unit), do: %{serial: "SIM-#{unit}", product_code: "ELITE440-445"}

  # The tests' local midnight; a time is milliseconds after it, on both clocks
  # unless a test sets the wall clock apart.
  @midnight ~N[2026-11-17 00:00:00.000]

  defp local(ms), do: NaiveDateTime.add(@midnight, ms, :millisecond)
  defp at(ms), do: %{monotonic: ms, local: local(ms)}
  defp at(monotonic, wall), do: %{monotonic: monotonic, local: local(wall)}

  @intervals %{1 => 60_000, 2 => 60_000, 3 => 10_000}

  # Each meter's last round started at the time given, none on a retry.
  defp ran(times),
    do:
      Map.new(times, fn {unit, ms} ->
        {unit, %{slot: Schedule.slot(local(ms), @intervals[unit]), retry_at: nil}}
      end)

  defp retry(due, unit, at), do: put_in(due[unit].retry_at, at)

  describe "next/4" do
    test "with nothing queued, a round starts over every meter due, in config order" do
      [m1, _m2, m3] = ms = meters()
      due = ran(%{1 => 0, 2 => 60_000, 3 => 0})

      assert {:start, %Job{kind: :poll_round, meters: [^m1, ^m3], started: 60_000}} =
               Schedule.next([], at(60_000), due, ms)
    end

    test "with nothing queued and nothing due, it waits until the first meter's next slot" do
      due = ran(%{1 => 60_000, 2 => 60_000, 3 => 60_000})
      assert Schedule.next([], at(61_000), due, meters()) == {:wait, 9_000}
    end

    test "a meter is due from the first instant of its next slot" do
      [_m1, m2, _m3] = ms = meters()
      due = ran(%{1 => 60_000, 2 => 0, 3 => 60_000})
      assert {:start, %Job{meters: [^m2]}} = Schedule.next([], at(60_000), due, ms)
      assert Schedule.next([], at(59_999), due, ms) == {:wait, 1}
    end

    test "a queued round is stepped, not restarted, while nothing is due" do
      [m1, m2, _m3] = ms = meters()
      round = [m1, m2] |> Job.poll_round(0) |> Job.polled([:read], {m1, seen(1), nil})

      assert Schedule.next([round], at(10), ran(%{1 => 0, 2 => 0, 3 => 0}), ms) ==
               {:step, round, []}
    end

    test "no new round starts while one is unfinished, even with its meters due again" do
      [m1, m2, m3] = ms = meters()
      round = Job.poll_round([m1, m2, m3], 0)

      assert Schedule.next([round], at(120_000), ran(%{1 => 0, 2 => 0, 3 => 0}), ms) ==
               {:step, round, []}
    end

    test "the first queued round of the highest rank runs, and the rest stay in order" do
      [m1, m2, m3] = ms = meters()
      a = Job.poll_round([m1], 0)
      b = Job.poll_round([m2], 1)
      c = Job.poll_round([m3], 2)

      assert Schedule.next([a, b, c], at(5), ran(%{1 => 0, 2 => 0, 3 => 0}), ms) ==
               {:step, a, [b, c]}
    end

    test "a read on demand runs before a round under way, and before a round due" do
      [m1, m2, m3] = ms = meters()
      round = [m1, m2] |> Job.poll_round(0) |> Job.polled([:read], {m1, seen(1), nil})
      {:ok, read} = Job.read_on_demand(ms, [3], 5, {self(), make_ref()})
      due = ran(%{1 => 60_000, 2 => 60_000, 3 => 55_000})

      assert Schedule.next([round, read], at(60_000), due, ms) == {:step, read, [round]}
      assert Schedule.next([read], at(60_000), due, ms) == {:step, read, []}

      assert {:start, %Job{kind: :poll_round, meters: [^m3]}} =
               Schedule.next([], at(60_000), due, ms)
    end
  end

  describe "next/4, across wall-clock steps" do
    test "slots passed by a clock set forward come to one round" do
      [m1, m2, m3] = ms = meters()
      due = ran(%{1 => 0, 2 => 0, 3 => 0})
      later = at(1_000, 5 * 3_600_000)

      assert {:start, %Job{meters: [^m1, ^m2, ^m3]} = round} = Schedule.next([], later, due, ms)
      due = Schedule.started(due, round, later)
      assert {:wait, _ms} = Schedule.next([], at(2_000, 5 * 3_600_000 + 1_000), due, ms)
    end

    test "after a clock set back, nothing is due until a slot later than the last one started" do
      ms = meters()
      due = ran(%{1 => 120_000, 2 => 120_000, 3 => 120_000})

      assert Schedule.next([], at(130_000, 61_000), due, ms) == {:wait, 69_000}
      assert Schedule.next([], at(190_000, 129_999), due, ms) == {:wait, 1}
      assert {:start, %Job{meters: [_m3]}} = Schedule.next([], at(190_001, 130_000), due, ms)
    end

    test "a round started after a clock set back marks no earlier slot than it had" do
      [m1 | _] = meters()
      due = ran(%{1 => 120_000, 2 => 0, 3 => 0})
      back = at(0, 61_000)

      assert Schedule.started(due, Job.poll_round([m1], 0), back)[1] == due[1]
    end
  end

  describe "next/4, with a meter on a retry" do
    test "it is due at its retry, which brings in no other meter, and waited for before its slot" do
      [_m1, m2, _m3] = ms = meters()
      due = ran(%{1 => 60_000, 2 => 60_000, 3 => 60_000}) |> retry(2, 65_000)
      due = put_in(due[3].slot, Schedule.slot(local(110_000), 10_000))

      assert Schedule.next([], at(61_000), due, ms) == {:wait, 4_000}
      assert {:start, %Job{meters: [^m2]}} = Schedule.next([], at(65_000), due, ms)
    end

    test "its next slot, when earlier than the retry, makes it due" do
      [m1, _m2, _m3] = ms = meters()
      due = ran(%{1 => 60_000, 2 => 110_000, 3 => 119_000}) |> retry(1, 150_000)

      assert Schedule.next([], at(110_000), due, ms) == {:wait, 10_000}
      assert {:start, %Job{meters: [^m1 | _]}} = Schedule.next([], at(120_000), due, ms)
    end

    test "its retry is on the monotonic clock, whatever the wall clock does" do
      [m1 | _] = ms = meters()
      due = ran(%{1 => 60_000, 2 => 60_000, 3 => 60_000}) |> retry(1, 65_000)

      assert {:start, %Job{meters: [^m1]}} = Schedule.next([], at(65_000, 0), due, ms)
    end
  end

  describe "next/4, with a copy queued" do
    test "a copy ranks below every other job: a round due, a round under way, a read on demand" do
      [m1, m2, _m3] = ms = meters()
      copy = Job.copy(ms, [], 0)
      rod = elem(Job.read_on_demand(ms, [1], 0, {self(), make_ref()}), 1)
      round = [m1, m2] |> Job.poll_round(0) |> Job.polled([:read], {m1, seen(1), nil})
      later = ran(%{1 => 60_000, 2 => 60_000, 3 => 60_000})
      now = at(60_100)

      assert {:start, %Job{kind: :poll_round}} =
               Schedule.next([copy], now, ran(%{1 => 0, 2 => 0, 3 => 0}), ms)

      assert Schedule.next([copy, round], now, later, ms) == {:step, round, [copy]}
      assert Schedule.next([copy, rod], now, later, ms) == {:step, rod, [copy]}

      assert Schedule.next([Job.restore(0, :backoff), copy], now, later, ms)
             |> elem(1)
             |> Map.fetch!(:kind) == :restore

      assert Schedule.next([copy], now, later, ms) == {:step, copy, []}
    end
  end

  describe "next/4, with a restore owed" do
    test "a ready restore runs before every other job, overdue round or read on demand" do
      [m1, m2, _m3] = ms = meters()
      round = [m1, m2] |> Job.poll_round(0) |> Job.polled([:read], {m1, seen(1), nil})
      {:ok, read} = Job.read_on_demand(ms, [3], 5, {self(), make_ref()})
      restore = Job.restore(5, :backoff)

      for due <- [ran(%{1 => 60_000, 2 => 60_000, 3 => 55_000}), ran(%{1 => 0, 2 => 0, 3 => 0})],
          now <- [at(60_100), at(1_000_000)] do
        assert Schedule.next([round, read, restore], now, due, ms) ==
                 {:step, restore, [round, read]}

        assert Schedule.next([restore], now, due, ms) == {:step, restore, []}
      end
    end

    test "a restore held back lets rounds and reads go on, and is waited for" do
      [m1, _m2, m3] = ms = meters()
      {:ok, read} = Job.read_on_demand(ms, [1], 5, {self(), make_ref()})
      restore = Job.restore(500, :backoff)
      none = ran(%{1 => 60_000, 2 => 60_000, 3 => 60_000})

      assert Schedule.next([restore, read], at(100, 60_100), none, ms) ==
               {:step, read, [restore]}

      assert {:start, %Job{meters: [^m1, ^m3]}} =
               Schedule.next([restore], at(100, 60_100), ran(%{1 => 0, 2 => 60_000, 3 => 0}), ms)

      assert Schedule.next([restore], at(100, 60_100), none, ms) == {:wait, 400}
      assert Schedule.next([restore], at(100, 69_800), none, ms) == {:wait, 200}
      assert Schedule.next([restore], at(500, 69_800), none, ms) == {:step, restore, []}
    end
  end

  describe "restore/3" do
    test "puts one restore at the head of the queue, held until the time given" do
      [m1 | _] = meters()
      round = Job.poll_round([m1], 0)

      assert [%Job{kind: :restore, not_before: 40}, ^round] =
               Schedule.restore([round], 40, :backoff)

      assert [%Job{kind: :restore, not_before: 7, held: :connection}, ^round] =
               [round] |> Schedule.restore(40, :backoff) |> Schedule.restore(7, :connection)
    end
  end

  describe "reconnected/2" do
    test "a restore held for want of a connection is ready at once; one held by backoff waits" do
      [m1 | _] = ms = meters()
      round = Job.poll_round([m1], 0)
      due = ran(%{1 => 60_000, 2 => 60_000, 3 => 60_000})

      queue = [round] |> Schedule.restore(5_000, :connection) |> Schedule.reconnected(100)

      assert {:step, %Job{kind: :restore}, [^round]} =
               Schedule.next(queue, at(100, 60_100), due, ms)

      queue = [round] |> Schedule.restore(5_000, :backoff) |> Schedule.reconnected(100)
      assert Schedule.next(queue, at(100, 60_100), due, ms) == {:step, round, [hd(queue)]}
    end
  end

  describe "next/4, with a meter overdue by its interval" do
    defp read(ms, units), do: elem(Job.read_on_demand(ms, units, 0, {self(), make_ref()}), 1)

    test "a round due starts ahead of a read on demand once a whole slot has passed without one" do
      [_m1, _m2, m3] = ms = meters()
      rod = read(ms, [1])
      due = ran(%{1 => 60_000, 2 => 60_000, 3 => 50_000})

      assert Schedule.next([rod], at(69_999), due, ms) == {:step, rod, []}

      assert {:start, %Job{kind: :poll_round, meters: [^m3], started: 70_000}} =
               Schedule.next([rod], at(70_000), due, ms)

      assert {:start, %Job{kind: :poll_round}} =
               Schedule.next([rod], at(1_000_000), ran(%{1 => 0, 2 => 0, 3 => 0}), ms)
    end

    test "a meter on a retry is overdue once its retry has been due for its interval" do
      [m1 | _] = ms = meters()
      rod = read(ms, [2])
      due = ran(%{1 => 60_000, 2 => 120_000, 3 => 120_000}) |> retry(1, 61_000)

      assert Schedule.next([rod], at(120_999), due, ms) == {:step, rod, []}

      assert {:start, %Job{meters: [^m1]}} = Schedule.next([rod], at(121_000), due, ms)
    end

    test "a round under way is stepped ahead of reads on demand, and they keep their order" do
      [m1, m2, _m3] = ms = meters()
      round = [m1, m2] |> Job.poll_round(0) |> Job.polled([:read], {m1, seen(1), nil})
      [a, b] = [read(ms, [3]), read(ms, [1])]
      due = ran(%{1 => 0, 2 => 0, 3 => 50_000})

      assert Schedule.next([a, round, b], at(120_000), due, ms) == {:step, round, [a, b]}
    end

    test "a stream of reads on demand, one more queued before every step, lets rounds run" do
      ms = meters()

      # Each step takes 1 s. The first round, over all three meters, runs at
      # once; then reads, until unit 3's slot at 70 s has passed, at 80 s; its
      # round, then reads again until 100 s.
      start = {[], Schedule.start(ms, at(60_000)), 60_000, %{reads: 0, rounds: 0}}

      {_queue, _due, _now, counts} =
        Enum.reduce(1..40, start, fn _step, {queue, due, now, counts} ->
          queue = queue ++ [read(ms, [3])]

          case Schedule.next(queue, at(now), due, ms) do
            {:start, round} ->
              stepped(round, queue, Schedule.started(due, round, at(now)), now, counts)

            {:step, %Job{kind: :read_on_demand}, rest} ->
              {rest, due, now + 1_000, Map.update!(counts, :reads, &(&1 + 1))}

            {:step, round, rest} ->
              stepped(round, rest, due, now, counts)
          end
        end)

      assert counts == %{reads: 36, rounds: 2}
    end

    # One meter step of `round`, back at the head of the queue unless it is done.
    defp stepped(round, rest, due, now, counts) do
      round = Job.polled(round, [:read], nil)

      case Job.next(round) do
        :done ->
          {rest, Schedule.after_round(due, round, now + 1_000), now + 1_000,
           Map.update!(counts, :rounds, &(&1 + 1))}

        _step ->
          {[round | rest], due, now + 1_000, counts}
      end
    end
  end

  describe "queue_read/2" do
    test "a read on demand joins the end of the queue, up to eight queued or under way" do
      [m1 | _] = ms = meters()
      round = Job.poll_round([m1], 0)
      reads = for unit <- [1, 2, 3, 1, 2, 3, 1, 2], do: read(ms, [unit])
      ninth = read(ms, [3])

      assert {:ok, queue} =
               Enum.reduce(reads, {:ok, [round]}, fn read, {:ok, queue} ->
                 Schedule.queue_read(queue, read)
               end)

      assert queue == [round | reads]
      assert Schedule.queue_read(queue, ninth) == {:error, :busy}
      fewer = Enum.drop(queue, -1)
      assert Schedule.queue_read(fewer, ninth) == {:ok, fewer ++ [ninth]}
    end
  end

  describe "slot/2" do
    test "counts a day's slots from local midnight, and runs on across midnight" do
      day = ~N[2026-11-17 00:00:00]
      quarter = 15 * 60_000
      six_hours = 6 * 3_600_000

      assert Schedule.slot(~N[2026-11-18 00:00:00], quarter) - Schedule.slot(day, quarter) == 96

      assert Schedule.slot(~N[2026-11-18 00:00:00], quarter) ==
               Schedule.slot(~N[2026-11-17 23:45:00], quarter) + 1

      assert Schedule.slot(~N[2026-11-17 23:59:59.999], quarter) ==
               Schedule.slot(~N[2026-11-17 23:45:00], quarter)

      assert for(
               t <- [~T[05:59:59], ~T[06:00:00], ~T[11:59:59], ~T[18:00:00]],
               do:
                 Schedule.slot(NaiveDateTime.new!(~D[2026-11-17], t), six_hours) -
                   Schedule.slot(day, six_hours)
             ) == [0, 1, 1, 3]
    end
  end

  describe "start/2" do
    test "every meter is due at once, then not again until its next slot" do
      [m1, m2, m3] = ms = meters()
      due = Schedule.start(ms, at(30_000))

      assert {:start, %Job{meters: [^m1, ^m2, ^m3]} = round} =
               Schedule.next([], at(30_000), due, ms)

      due = Schedule.started(due, round, at(30_000))
      assert Schedule.next([], at(30_500), due, ms) == {:wait, 9_500}
      assert {:start, %Job{meters: [^m3]}} = Schedule.next([], at(40_000), due, ms)
      assert {:start, %Job{meters: [^m1, ^m2, ^m3]}} = Schedule.next([], at(60_000), due, ms)
    end
  end

  describe "started/3" do
    test "a retry round in the slot already started marks nothing new; one in a later slot marks it" do
      [m1 | _] = meters()
      due = ran(%{1 => 60_000, 2 => 0, 3 => 0}) |> retry(1, 90_000)
      round = Job.poll_round([m1], 90_000)

      assert Schedule.started(due, round, at(90_000))[1].slot == due[1].slot
      assert Schedule.started(due, round, at(120_000))[1].slot == due[1].slot + 1
    end
  end

  describe "after_round/3" do
    test "a meter not reached retries a retry interval after the round ended; one reached does not" do
      [m1, _m2, m3] = meters()
      due = ran(%{1 => 0, 2 => 0, 3 => 0}) |> retry(1, 100) |> retry(2, 200)
      round = [m1, m3] |> Job.poll_round(0) |> Job.unreached(3)

      after_ = Schedule.after_round(due, round, 5_000)
      assert after_[1].retry_at == nil
      assert after_[2].retry_at == 200
      assert after_[3].retry_at == 65_000

      assert Enum.map(after_, fn {_unit, d} -> d.slot end) ==
               Enum.map(due, fn {_unit, d} -> d.slot end)
    end

    test "a round that overran its interval leaves its meters due at once" do
      [m1, m2, m3] = ms = meters()
      round = Job.poll_round(ms, 0)
      due = ms |> Schedule.start(at(0)) |> Schedule.started(round, at(0))
      due = Schedule.after_round(due, round, 12_000)

      assert {:start, %Job{meters: [^m3], started: 12_000}} =
               Schedule.next([], at(12_000), due, [m1, m2, m3])
    end
  end

  describe "due_at/3" do
    test "a meter's next slot, or its retry when that comes first, in local time" do
      [m1 | _] = meters()
      due = ran(%{1 => 60_000})[1]

      assert Schedule.due_at(due, m1, at(61_000)) == %{at: local(120_000), retrying: false}

      assert Schedule.due_at(%{due | retry_at: 65_000}, m1, at(61_000)) ==
               %{at: local(65_000), retrying: true}

      assert Schedule.due_at(%{due | retry_at: 200_000}, m1, at(61_000)) ==
               %{at: local(120_000), retrying: true}
    end
  end

  describe "retired/1" do
    test "a round not yet begun goes; one begun, reads on demand and a restore stay" do
      [m1, m2, _m3] = meters()
      waiting = Job.poll_round([m1, m2], 0)
      begun = Job.polled(waiting, [:read], {m1, seen(1), nil})
      {:ok, read} = Job.read_on_demand([m1, m2], [2], 0, {self(), make_ref()})
      restore = Job.restore(0, :backoff)

      assert Schedule.retired([restore, waiting, read]) == [restore, read]
      assert Schedule.retired([begun, read]) == [begun, read]
    end

    test "with no meters, no round starts: the queue drains, and a held restore is waited for" do
      [m1, _m2, _m3] = meters()
      {:ok, read} = Job.read_on_demand([m1], [1], 0, {self(), make_ref()})
      held = Job.restore(500, :backoff)

      assert Schedule.next([read], at(100), %{}, []) == {:step, read, []}
      assert Schedule.next([held], at(100), %{}, []) == {:wait, 400}
    end
  end
end
