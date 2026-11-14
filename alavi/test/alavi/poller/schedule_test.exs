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

  describe "next/4, with a restore owed" do
    test "a ready restore runs before every other job, overdue round or read on demand" do
      [m1, m2, _m3] = ms = meters()
      round = [m1, m2] |> Job.poll_round(0) |> Job.polled([:read], {m1, seen(1), nil})
      {:ok, read} = Job.read_on_demand(ms, [3], 5, {self(), make_ref()})
      restore = Job.restore(5, :backoff)

      for due <- [%{1 => 60_000, 2 => 60_000, 3 => 0}, %{1 => 0, 2 => 0, 3 => 0}],
          now <- [5, 1_000_000] do
        assert Schedule.next([round, read, restore], now, due, ms) ==
                 {:step, restore, [round, read]}

        assert Schedule.next([restore], now, due, ms) == {:step, restore, []}
      end
    end

    test "a restore held back lets rounds and reads go on, and is waited for" do
      [m1, _m2, m3] = ms = meters()
      {:ok, read} = Job.read_on_demand(ms, [1], 5, {self(), make_ref()})
      restore = Job.restore(500, :backoff)

      assert Schedule.next([restore, read], 100, %{1 => 900, 2 => 900, 3 => 900}, ms) ==
               {:step, read, [restore]}

      assert {:start, %Job{meters: [^m1, ^m3]}} =
               Schedule.next([restore], 100, %{1 => 50, 2 => 900, 3 => 60}, ms)

      assert Schedule.next([restore], 100, %{1 => 900, 2 => 900, 3 => 900}, ms) == {:wait, 400}
      assert Schedule.next([restore], 100, %{1 => 300, 2 => 900, 3 => 900}, ms) == {:wait, 200}

      assert Schedule.next([restore], 500, %{1 => 300, 2 => 900, 3 => 900}, ms) ==
               {:step, restore, []}
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
      due = %{1 => 9_000, 2 => 9_000, 3 => 9_000}

      queue = [round] |> Schedule.restore(5_000, :connection) |> Schedule.reconnected(100)
      assert {:step, %Job{kind: :restore}, [^round]} = Schedule.next(queue, 100, due, ms)

      queue = [round] |> Schedule.restore(5_000, :backoff) |> Schedule.reconnected(100)
      assert Schedule.next(queue, 100, due, ms) == {:step, round, [hd(queue)]}
    end
  end

  describe "next/4, with a meter overdue by its interval" do
    defp read(ms, units), do: elem(Job.read_on_demand(ms, units, 0, {self(), make_ref()}), 1)

    test "a round due starts ahead of a read on demand once a meter is a whole interval late" do
      [_m1, _m2, m3] = ms = meters()
      rod = read(ms, [1])
      due = %{1 => 60_000, 2 => 60_000, 3 => 0}

      assert Schedule.next([rod], 9_999, due, ms) == {:step, rod, []}

      assert {:start, %Job{kind: :poll_round, meters: [^m3], started: 10_000}} =
               Schedule.next([rod], 10_000, due, ms)

      assert {:start, %Job{kind: :poll_round}} =
               Schedule.next([rod], 1_000_000, %{1 => 0, 2 => 0, 3 => 0}, ms)
    end

    test "a round under way is stepped ahead of reads on demand, and they keep their order" do
      [m1, m2, _m3] = ms = meters()
      round = [m1, m2] |> Job.poll_round(0) |> Job.polled([:read], {m1, seen(1), nil})
      [a, b] = [read(ms, [3]), read(ms, [1])]
      due = %{1 => 0, 2 => 0, 3 => 10_000}

      assert Schedule.next([a, round, b], 60_000, due, ms) == {:step, round, [a, b]}
    end

    test "a stream of reads on demand, one more queued before every step, lets rounds run" do
      ms = meters()

      # Each step takes 1 s. The first round, over all three meters, runs at
      # once; then reads, until unit 3 is 10 s overdue at 80 s; its round,
      # then reads again until 100 s.
      {_queue, _due, _now, counts} =
        Enum.reduce(1..40, {[], %{1 => 0, 2 => 0, 3 => 0}, 60_000, %{reads: 0, rounds: 0}}, fn
          _step, {queue, due, now, counts} ->
            queue = queue ++ [read(ms, [3])]

            case Schedule.next(queue, now, due, ms) do
              {:start, round} ->
                stepped(round, queue, due, now, counts)

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
          {rest, Schedule.after_round(due, round), now + 1_000,
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
