defmodule Alavi.Copy.RunTest do
  use ExUnit.Case, async: true

  alias Alavi.Copy.Run

  defp visit(meter),
    do: %{
      meter: meter,
      serial: "S",
      product_code: "P",
      progress: %{},
      clock: [0, 0],
      stores: [:snapshot]
    }

  describe "new/1" do
    test "visits the meters in order, and is done after the last" do
      run = Run.new([:m1, :m2])
      assert run.phase == {:visit, :m1}
      run = Run.next_meter(run)
      assert run.phase == {:visit, :m2}
      assert Run.done?(Run.next_meter(run))
      assert Run.done?(Run.new([]))
      assert Run.outcome(Run.next_meter(run)) == :done
    end

    test "stopped, it closes the session open and reads the clock, then starts no visit" do
      scope = %{store: :history}
      run = %{Run.new([:m1, :m2]) | phase: {:copy, visit(:m1), scope}}
      stopped = Run.stop(run, :window)

      assert {:close, %{stores: []}, ^scope} = stopped.phase
      assert Run.stop(stopped, :retiring).stop == :window
      assert Run.done?(Run.next_meter(stopped))
      assert Run.outcome(stopped) == :window
    end

    test "stopped before a visit starts, it is done at once; mid-visit, its clock is read first" do
      assert Run.done?(Run.stop(Run.new([:m1]), :retiring))
      run = %{Run.new([:m1]) | phase: {:open, visit(:m1)}}
      assert {:end_visit, _} = Run.stop(run, :retiring).phase
    end

    test "faulted, it is done, whatever is left" do
      run = Run.faulted(Run.new([:m1, :m2]))
      assert Run.done?(run)
      assert Run.outcome(run) == :fault
    end
  end
end
