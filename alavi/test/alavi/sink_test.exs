defmodule Alavi.SinkTest do
  use ExUnit.Case, async: true

  alias Alavi.Sink

  defmodule Answers do
    @behaviour Alavi.Sink

    @impl true
    def record(answer, _events), do: answer
  end

  describe "record/2" do
    test "passes on :ok and an error, and raises on any other answer" do
      assert :ok = Sink.record({Answers, :ok}, [:event])
      assert {:error, :full} = Sink.record({Answers, {:error, :full}}, [:event])
      assert_raise CaseClauseError, fn -> Sink.record({Answers, :maybe}, [:event]) end
    end
  end
end
