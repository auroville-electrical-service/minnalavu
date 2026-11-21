defmodule Alavi.Copy.FillTest do
  use ExUnit.Case, async: true

  alias Alavi.Copy.Fill

  @fill Fill.new(
          "7d2c1f0e-4b3a-4c5d-8e6f-1a2b3c4d5e6f",
          ["SIM-1", "SIM-3"],
          [:load_survey, :history],
          ~N[2026-10-01 00:00:00],
          ~N[2026-11-01 00:00:00],
          ~U[2026-11-04 00:00:00Z]
        )

  describe "due/2" do
    test "a meter it names owes its stores in the order asked, less those done; any other owes none" do
      assert Fill.due(@fill, "SIM-1") == [:load_survey, :history]
      assert @fill |> Fill.done("SIM-1", :load_survey) |> Fill.due("SIM-1") == [:history]

      assert @fill |> Fill.done("SIM-1", :load_survey) |> Fill.due("SIM-3") == [
               :load_survey,
               :history
             ]

      assert Fill.due(@fill, "SIM-2") == []
    end

    test "it has expired from its expires_at on" do
      refute Fill.expired?(@fill, ~U[2026-11-03 23:59:59Z])
      assert Fill.expired?(@fill, ~U[2026-11-04 00:00:00Z])
    end
  end
end
