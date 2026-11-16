defmodule Alavi.Clock.WindowsTest do
  use ExUnit.Case, async: true

  import Alavi.PollerCase, only: [start_status!: 1, eventually!: 1]
  import ExUnit.CaptureLog

  alias Alavi.Clock.Windows

  @now ~U[2026-11-11 10:00:00Z]
  @ntp "Leap Indicator: 0(no warning)\r\nSource: 192.0.2.1\r\nTime since Last Good Sync Time: 60.0s\r\n"
  @cmos "Leap Indicator: 0(no warning)\r\nSource: Local CMOS Clock\r\n"

  # A query that answers with the scripted outputs in turn (repeating the
  # last), and counts how often it ran.
  defp scripted(answers) do
    {:ok, agent} = Agent.start_link(fn -> {answers, 0} end)

    query = fn ->
      Agent.get_and_update(agent, fn {[answer | rest], n} ->
        {answer, {if(rest == [], do: [answer], else: rest), n + 1}}
      end)
    end

    {query, fn -> Agent.get(agent, &elem(&1, 1)) end}
  end

  defp start!(query, refresh_ms, status \\ Alavi.NoStatus) do
    start_supervised!(
      {Windows, query: query, clock: fn -> @now end, refresh_ms: refresh_ms, status: status}
    )
  end

  defp await_status!(pid, expected, tries \\ 100) do
    cond do
      Windows.status(pid) == expected -> :ok
      tries > 0 -> Process.sleep(10) && await_status!(pid, expected, tries - 1)
      true -> flunk("status never became #{inspect(expected)}: #{inspect(Windows.status(pid))}")
    end
  end

  describe "status/1" do
    test "reads are answered from the cached status, not by running the query" do
      {query, runs} = scripted([{:ok, @ntp}])
      pid = start!(query, 60_000)
      :ok = await_status!(pid, %{source: :ntp, last_sync_at: ~U[2026-11-11 09:59:00Z]})

      for _ <- 1..50, do: Windows.status(pid)
      assert runs.() == 1
    end

    test "the status is refreshed every refresh_ms" do
      {query, runs} = scripted([{:ok, @ntp}, {:ok, @cmos}])
      pid = start!(query, 50)

      :ok = await_status!(pid, %{source: :rtc, last_sync_at: nil})
      assert runs.() >= 2
    end

    @tag :tmp_dir
    test "each answer reaches the status", %{tmp_dir: dir} do
      status = start_status!(dir)
      start!(fn -> {:ok, @ntp} end, 60_000, status)

      :ok =
        eventually!(fn ->
          Alavi.Status.read(status).clock == %{
            source: "ntp",
            last_sync_at: "2026-11-11T09:59:00Z"
          }
        end)
    end

    test "unsynced until the first answer" do
      pid = start!(fn -> Process.sleep(:infinity) end, 60_000)
      assert Windows.status(pid) == %{source: :unsynced, last_sync_at: nil}
    end

    test "an unrecognised answer is unsynced, logged once with the raw output" do
      {query, _runs} = scripted([{:ok, @ntp}, {:ok, "Quelle: Lokale CMOS-Uhr"}])

      # The first answer stands for a whole refresh: long enough to be seen on
      # a loaded machine before the failing one replaces it.
      log =
        capture_log(fn ->
          pid = start!(query, 300)
          :ok = await_status!(pid, %{source: :ntp, last_sync_at: ~U[2026-11-11 09:59:00Z]})
          :ok = await_status!(pid, %{source: :unsynced, last_sync_at: nil})
          Process.sleep(200)
        end)

      assert [_] = Regex.scan(~r/\[warning\].*not recognised: Quelle: Lokale CMOS-Uhr/, log)
    end

    test "a failing query is unsynced, logged with the reason" do
      {query, _} = scripted([{:ok, @ntp}, {:error, "w32tm exited with status 1: no service"}])

      # The first answer stands for a whole refresh: long enough to be seen on
      # a loaded machine before the failing one replaces it.
      log =
        capture_log(fn ->
          pid = start!(query, 300)
          :ok = await_status!(pid, %{source: :ntp, last_sync_at: ~U[2026-11-11 09:59:00Z]})
          :ok = await_status!(pid, %{source: :unsynced, last_sync_at: nil})
        end)

      assert log =~ "reporting the clock as unsynced: w32tm exited with status 1: no service"
    end

    test "a query still running at the next refresh is abandoned; status still answers" do
      log =
        capture_log(fn ->
          pid = start!(fn -> Process.sleep(:infinity) end, 30)
          Process.sleep(100)
          assert Windows.status(pid) == %{source: :unsynced, last_sync_at: nil}
        end)

      assert [_] = Regex.scan(~r/w32tm did not answer within 30 ms/, log)
    end
  end

  describe "w32tm/0" do
    test "w32tm/0 off Windows reports that the command cannot run, without raising" do
      if :os.type() |> elem(0) != :win32 do
        assert {:error, "w32tm cannot be run: " <> _} = Windows.w32tm()
      end
    end
  end
end
