defmodule Alavi.Copy.ProgressTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Alavi.Copy.Progress

  @moduletag :tmp_dir

  @progress %{history: ~N[2026-11-01 00:00:00], load_survey: ~N[2026-11-15 00:00:00]}

  describe "load/2" do
    test "a meter with no file has copied nothing", %{tmp_dir: dir} do
      assert Progress.load(Path.join(dir, "none"), "SIM-1") == {:ok, %{}}
    end

    test "what was saved reads back, per serial; a later save replaces it", %{tmp_dir: dir} do
      assert :ok = Progress.save(dir, "SIM-1", @progress)
      assert Progress.load(dir, "SIM-1") == {:ok, @progress}
      assert Progress.load(dir, "SIM-2") == {:ok, %{}}

      later = Map.put(@progress, :snapshot, ~N[2026-11-16 00:00:00])
      assert :ok = Progress.save(dir, "SIM-1", later)
      assert Progress.load(dir, "SIM-1") == {:ok, later}
      refute File.exists?(Path.join(dir, "SIM-1.copied.new"))
    end

    test "a new file left whole by a crash before its rename is the newer; a torn one is passed over",
         %{tmp_dir: dir} do
      :ok = Progress.save(dir, "SIM-1", @progress)
      newer = %{history: ~N[2026-12-01 00:00:00]}
      File.write!(Path.join(dir, "SIM-1.copied.new"), Progress.encode("SIM-1", newer))
      assert Progress.load(dir, "SIM-1") == {:ok, newer}

      File.write!(Path.join(dir, "SIM-1.copied.new"), "{\"format\"")
      log = capture_log(fn -> assert Progress.load(dir, "SIM-1") == {:ok, @progress} end)
      assert log =~ "passed over"
    end

    test "a file that does not read whole, or names another meter, is refused", %{tmp_dir: dir} do
      path = Path.join(dir, "SIM-1.copied")
      File.write!(path, "nope")
      assert {:error, {:unreadable, ^path, "not JSON"}} = Progress.load(dir, "SIM-1")

      File.write!(path, Progress.encode("SIM-9", @progress))
      assert {:error, {:unreadable, ^path, message}} = Progress.load(dir, "SIM-1")
      assert message =~ ~s(names meter "SIM-9")

      assert {:error, _} =
               Progress.parse(
                 ~s({"format": "alavi-copy-progress.v1", "meter_serial": "SIM-1", "stores": {"events": "2026-11-01T00:00:00"}}),
                 "SIM-1"
               )

      assert {:error, _} =
               Progress.parse(
                 ~s({"format": "alavi-copy-progress.v1", "meter_serial": "SIM-1", "stores": {"history": 5}}),
                 "SIM-1"
               )
    end

    test "a serial a file name may not hold is kept under a safe name, and still names itself",
         %{tmp_dir: dir} do
      :ok = Progress.save(dir, "A/B C", @progress)
      assert File.exists?(Path.join(dir, "A_B_C.copied"))
      assert Progress.load(dir, "A/B C") == {:ok, @progress}
    end
  end
end
