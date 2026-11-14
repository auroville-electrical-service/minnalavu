defmodule Alavi.Poller.JobTest do
  use ExUnit.Case, async: true

  import Alavi.PollerCase

  alias Alavi.Poller.Job

  defp meters do
    config = config!([endpoint(502, "tcp", [meter(1, "elite_440"), meter(2, "elite_440")])])
    hd(config.endpoints).meters
  end

  defp seen(unit), do: %{serial: "SIM-#{unit}", product_code: "ELITE440-445"}

  describe "poll_round/2" do
    test "steps through each meter, then the names of each identified meter, in order" do
      [m1, m2] = meters()
      job = Job.poll_round([m1, m2], 7)

      assert %Job{kind: :poll_round, meters: [^m1, ^m2], started: 7, down: nil} = job
      assert Job.next(job) == {:meter, m1}

      job = Job.polled(job, [:a, :b], {m1, seen(1), nil})
      assert Job.next(job) == {:meter, m2}

      job = Job.polled(job, [:c], {m2, seen(2), :timeout})
      assert Job.next(job) == {:names, {m1, seen(1), nil}}

      job = Job.named(job)
      assert Job.next(job) == {:names, {m2, seen(2), :timeout}}
      assert Job.next(Job.named(job)) == :done
      assert Job.events(job) == [:a, :b, :c]
    end

    test "a meter not identified has no names step" do
      [m1, m2] = meters()

      job =
        [m1, m2]
        |> Job.poll_round(0)
        |> Job.polled([:missed], nil)
        |> Job.polled([:read], {m2, seen(2), nil})

      assert Job.next(job) == {:names, {m2, seen(2), nil}}
      assert Job.next(Job.named(job)) == :done
    end

    test "a round over no meters is done at once, with no events" do
      job = Job.poll_round([], 0)
      assert Job.next(job) == :done
      assert Job.events(job) == []
    end

    test "the endpoint going down is held for the rest of the round" do
      [m1, m2] = meters()
      job = [m1, m2] |> Job.poll_round(0) |> Job.down(:econnrefused) |> Job.polled([], nil)
      assert %Job{down: :econnrefused} = job
      assert Job.next(job) == {:meter, m2}
    end
  end
end
