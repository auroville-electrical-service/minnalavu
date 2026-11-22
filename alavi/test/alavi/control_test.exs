defmodule Alavi.ControlTest do
  use ExUnit.Case, async: true

  import Alavi.PollerCase
  import ExUnit.CaptureLog

  alias Alavi.{Control, Pollers}

  @moduletag :tmp_dir

  defp pollers! do
    {_sim, port} = start_sim!(:tcp)
    start_pollers!([endpoint(port, "tcp", [meter(1, "elite_440")], %{"interval_ms" => 50})])
  end

  defp running(pollers),
    do: pollers |> Pollers.pollers() |> Enum.count(fn {_id, child} -> is_pid(child) end)

  # Polls for `path`, as stop.ps1 does, up to `ms`.
  defp await_file!(path, ms) when ms > 0 do
    if File.exists?(path) do
      File.read!(path)
    else
      Process.sleep(20)
      await_file!(path, ms - 20)
    end
  end

  defp await_file!(path, _ms), do: flunk("no #{path}")

  describe "start_link/1" do
    test "writes ready, and removes a request and an answer left from before", ctx do
      dir = Path.join(ctx.tmp_dir, "control")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "quiesce"), "")
      File.write!(Path.join(dir, "quiesced"), "{}")
      pollers = pollers!()

      log =
        capture_log(fn ->
          start_supervised!({Control, dir: dir, pollers: pollers, check_ms: 20})
          Process.sleep(100)
        end)

      assert File.exists?(Path.join(dir, "ready"))
      refute File.exists?(Path.join(dir, "quiesce"))
      refute File.exists?(Path.join(dir, "quiesced"))
      assert log =~ "quiesce left from before this start removed"
      assert running(pollers) == 1
    end

    test "a quiesce request retires every poller, then quiesced says none is running", ctx do
      dir = Path.join(ctx.tmp_dir, "control")
      pollers = pollers!()
      start_supervised!({Control, dir: dir, pollers: pollers, check_ms: 20})
      await_file!(Path.join(dir, "ready"), 1_000)

      log =
        capture_log(fn ->
          File.write!(Path.join(dir, "quiesce"), "")
          answer = dir |> Path.join("quiesced") |> await_file!(5_000) |> JSON.decode!()
          assert %{"running" => 0, "at" => _at} = answer
        end)

      assert running(pollers) == 0
      assert log =~ "not polled while the collector stops"
    end

    test "a directory it cannot use leaves the collector running without it", ctx do
      blocked = Path.join(ctx.tmp_dir, "a-file")
      File.write!(blocked, "")
      pollers = pollers!()

      log =
        capture_log(fn ->
          assert :ignore = Control.init(dir: Path.join(blocked, "control"), pollers: pollers)
        end)

      assert log =~ "a planned stop is an ordinary one"
      assert running(pollers) == 1
    end
  end
end
