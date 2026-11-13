defmodule Alavi.Poller.PolicyTest do
  use ExUnit.Case, async: true

  alias Alavi.Poller.Policy

  @endpoint %{retries: 1, busy_backoff_ms: 50}

  describe "next/2" do
    test "exception 0A, like 0B, misses the meter without a retry" do
      assert Policy.next({:exception, 0x0A}, 1, @endpoint) == :skip_meter
      assert Policy.next({:exception, 0x0B}, 1, @endpoint) == :skip_meter
    end

    test "any other exception misses only that register, without a retry" do
      for code <- [1, 2, 3, 4, 7, 8] do
        assert Policy.next({:exception, code}, 1, @endpoint) == :skip_register
      end
    end

    test "exception 05, like 06, waits and retries, then misses the meter" do
      for code <- [5, 6] do
        assert Policy.next({:exception, code}, 1, @endpoint) == {:retry_after, 50}
        assert Policy.next({:exception, code}, 2, @endpoint) == :skip_meter
      end
    end

    test "a transport error is retried at once, then misses the meter" do
      for error <- [:closed, :timeout, {:socket, :econnreset}] do
        assert Policy.next(error, 1, @endpoint) == :retry
        assert Policy.next(error, 2, @endpoint) == :skip_meter
      end
    end
  end

  describe "backoff/2" do
    test "doubles the wait, at most max" do
      limits = %{min: 100, max: 1000}
      assert Policy.backoff(400, limits) == 800
      assert Policy.backoff(800, limits) == 1000
    end
  end
end
