defmodule Alavi.Poller.LatencyTest do
  use ExUnit.Case, async: true

  alias Alavi.Poller.Latency

  @day ~D[2026-11-14]

  defp answers(latency \\ Latency.new(), date \\ @day, ms_list),
    do: Enum.reduce(ms_list, latency, &Latency.record(&2, date, 1, &1, :ok))

  describe "record/5" do
    test "a reply, or a meter's own exception, is a sample; a retry's is counted as one" do
      summary =
        Latency.new()
        |> Latency.record(@day, 1, 40, :ok)
        |> Latency.record(@day, 2, 45, :ok)
        |> Latency.record(@day, 1, 30, {:exception, 2})
        |> Latency.record(@day, 3, 50, {:exception, 6})
        |> Latency.summary()

      assert %{answered: 4, retries: 2, timeouts: 0, max: 50} = summary
    end

    test "a timeout, and the gateway's exception 0B, are counted and are not samples" do
      summary =
        answers([40])
        |> Latency.record(@day, 1, 3_000, :timeout)
        |> Latency.record(@day, 2, 2_000, {:exception, 0x0B})
        |> Latency.summary()

      assert %{answered: 1, timeouts: 2, max: 40, p99: 40} = summary
    end

    test "0A and transport faults other than a timeout are neither" do
      latency = answers([40])

      for outcome <- [{:exception, 0x0A}, :closed, {:socket, :econnreset}, :bad_crc] do
        assert Latency.record(latency, @day, 1, 5, outcome) == latency
      end
    end

    test "only timeouts: counted, with no percentiles" do
      summary = Latency.new() |> Latency.record(@day, 1, 100, :timeout) |> Latency.summary()
      assert summary == %{since: @day, answered: 0, retries: 0, timeouts: 1} |> no_figures()
    end

    test "a new day starts a new histogram; days a week older than the newest are dropped" do
      latency =
        Enum.reduce(0..9, Latency.new(), fn n, l -> answers(l, Date.add(@day, n), [10]) end)

      assert %{since: since, answered: 7} = Latency.summary(latency)
      assert since == Date.add(@day, 3)
      assert Latency.line(latency, Date.add(@day, 2)) == nil
      assert Latency.line(latency, Date.add(@day, 3)) =~ " 1 answered"
    end

    test "a day with nothing between keeps the days still within the week" do
      latency =
        answers([10]) |> answers(Date.add(@day, 6), [20]) |> answers(Date.add(@day, 7), [30])

      assert %{since: since, answered: 2, max: 30} = Latency.summary(latency)
      assert since == Date.add(@day, 6)
    end

    test "a date before the newest kept counts in the newest" do
      latency = answers([10]) |> answers(Date.add(@day, -1), [20])
      assert %{since: @day, answered: 2} = Latency.summary(latency)
      assert Latency.line(latency, Date.add(@day, -1)) == nil
    end

    test "stays bounded whatever the number of requests" do
      latency = answers(Enum.flat_map(1..200, fn _ -> Enum.to_list(0..70_000//97) end))
      [{@day, day}] = latency.days
      assert map_size(day.buckets) <= 44
      assert %{answered: 144_400, max: 69_937} = Latency.summary(latency)
    end
  end

  describe "summary/1" do
    # The store's test of store.latency_meter_days (central/test/latency.sql)
    # counts the same answers.
    test "nearest rank at each edge: the smallest bucket holding at least p % of the answers" do
      ms = List.duplicate(1, 49) ++ [2] ++ List.duplicate(3, 40) ++ List.duplicate(4, 9) ++ [5]
      assert %{answered: 100, p50: 2, p90: 3, p99: 4, max: 5} = Latency.summary(answers(ms))
    end

    test "nil before anything was recorded" do
      assert Latency.summary(Latency.new()) == nil
    end

    test "nearest-rank percentiles, as the bound of their bucket, never above the max" do
      # 1..100 ms: p50 is 50, p90 90 (bucket 80..100, bound 100), p99 99 (bound 100).
      summary = Latency.summary(answers(Enum.to_list(1..100)))
      assert %{p50: 50, p90: 100, p99: 100, max: 100, answered: 100} = summary

      # 98 fast answers and 2 slow: p99 falls in the slow bucket, capped at the max.
      summary = Latency.summary(answers(List.duplicate(4, 98) ++ [1_100, 1_130]))
      assert %{p50: 4, p90: 4, p99: 1_130, max: 1_130} = summary

      # One in a hundred slow: p99 is still the fast bucket.
      summary = Latency.summary(answers(List.duplicate(37, 99) ++ [900]))
      assert %{p50: 40, p90: 40, p99: 40, max: 900} = summary
    end

    test "an answer above the last bound is in the overflow bucket, read as the max" do
      assert %{p50: 75_000, max: 75_000} = Latency.summary(answers([75_000]))
    end

    test "merges every day kept" do
      latency = answers([10, 10]) |> answers(Date.add(@day, 1), [500, 500, 500])
      assert %{since: @day, answered: 5, p50: 500, max: 500} = Latency.summary(latency)
    end
  end

  describe "line/2" do
    test "one day's figures and its bucket counts" do
      latency =
        answers([3, 38, 40, 41, 75_000])
        |> Latency.record(@day, 2, 44, :ok)
        |> Latency.record(@day, 1, 3_000, :timeout)

      assert Latency.line(latency, @day) ==
               "2026-11-14 UTC: 6 answered (1 on a retry), 1 timed out; " <>
                 "p50 40 ms, p90 75000 ms, p99 75000 ms, max 75000 ms; " <>
                 "buckets 3:1 40:2 50:2 >60000:1"
    end

    test "a day of timeouts only" do
      latency = Latency.record(Latency.new(), @day, 1, 100, :timeout)

      assert Latency.line(latency, @day) ==
               "2026-11-14 UTC: 0 answered (0 on a retry), 1 timed out; " <>
                 "p50 none, p90 none, p99 none, max none; buckets none"
    end

    test "nil for a day not kept" do
      assert Latency.line(answers([5]), Date.add(@day, 1)) == nil
    end
  end

  describe "counts/2" do
    test "every bucket's count in order, one above the last bound, with the day's figures" do
      latency =
        answers([3, 38, 40, 41, 75_000])
        |> Latency.record(@day, 2, 44, :ok)
        |> Latency.record(@day, 1, 3_000, :timeout)

      assert %{retries: 1, timeouts: 1, max: 75_000, buckets: buckets} =
               Latency.counts(latency, @day)

      assert length(buckets) == length(Latency.bounds()) + 1
      assert Enum.sum(buckets) == 6
      by_bound = Enum.zip(Latency.bounds() ++ [:over], buckets)
      assert Enum.reject(by_bound, &(elem(&1, 1) == 0)) == [{3, 1}, {40, 2}, {50, 2}, {:over, 1}]
    end

    test "a day of timeouts only has every bucket empty and no max" do
      latency = Latency.record(Latency.new(), @day, 1, 100, :timeout)
      assert %{timeouts: 1, max: nil, buckets: buckets} = Latency.counts(latency, @day)
      assert Enum.all?(buckets, &(&1 == 0))
    end

    test "nil for a day not kept" do
      assert Latency.counts(answers([5]), Date.add(@day, 1)) == nil
    end
  end

  describe "bounds/0" do
    test "are the bounds of the contract's version that bucket_version/0 names" do
      version = Latency.bucket_version()
      path = Path.expand("../../../../contract/latency/buckets.v#{version}.json", __DIR__)
      contract = path |> File.read!() |> JSON.decode!()

      assert contract["version"] == version
      assert contract["bounds_ms"] == Latency.bounds()
    end
  end

  defp no_figures(map), do: Map.merge(map, %{p50: nil, p90: nil, p99: nil, max: nil})
end
