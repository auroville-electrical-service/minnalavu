defmodule Alavi.Poller.RawLogTest do
  use ExUnit.Case, async: true

  import Alavi.PollerCase
  import ExUnit.CaptureLog

  alias Alavi.Poller.RawLog

  @limits %{max_frame_bytes: 4, max_lines: 2, window_ms: 1000}
  @noise %{kind: :skipped, unit_id: 7, reasons: [:noise, :bad_crc], bytes: <<1, 2, 3>>}

  defp log, do: RawLog.new("10.0.0.21:502", @limits)

  describe "note/3 and flush/2" do
    test "a line names the endpoint, unit, reasons and the bytes in hex" do
      assert {[line], _} = RawLog.note(log(), [@noise], 0)

      assert line ==
               "alavi poller 10.0.0.21:502 unit 7: 3 bytes skipped before the reply (noise, bad CRC): 01 02 03"
    end

    test "a rejected reply names its reason" do
      rejected = %{kind: :rejected, unit_id: 2, reason: :malformed_response, bytes: <<4, 3>>}
      assert {[line], _} = RawLog.note(log(), [rejected], 0)
      assert line =~ "unit 2: reply rejected (:malformed_response), 2 bytes: 04 03"
    end

    test "at most max_frame_bytes bytes are shown, with the full count" do
      long = %{@noise | bytes: :binary.copy(<<0xAB>>, 300)}
      assert {[line], _} = RawLog.note(log(), [long], 0)
      assert line =~ "300 bytes skipped"
      assert line =~ ~r/: AB AB AB AB \(first 4 shown\)$/
    end

    test "at most max_lines lines per window, then one line counts the rest" do
      {lines, log} = RawLog.note(log(), List.duplicate(@noise, 5), 0)
      assert length(lines) == 2
      assert {[], log} = RawLog.note(log, [@noise], 999)
      assert {[summary], log} = RawLog.flush(log, 1000)
      assert summary =~ "4 more raw-bytes line(s) suppressed in 1000 ms (at most 2 per 1000 ms)"
      assert {[], _} = RawLog.flush(log, 5000)
    end

    test "a window with nothing suppressed ends without a summary, and the next logs again" do
      {[_], log} = RawLog.note(log(), [@noise], 0)
      assert {[line], _} = RawLog.note(log, [@noise], 1500)
      assert line =~ "unit 7"
    end
  end

  describe "a poller" do
    # One meter, four registers: one anomaly per register read.
    defp poll!(framing, faults, limits, ms) do
      {sim, port} = start_sim!(framing)
      Simulator.faults(sim, faults)

      endpoint =
        endpoint(port, Atom.to_string(framing), [meter(1, "elite_440")], %{"interval_ms" => 50})

      log =
        capture_log(fn ->
          start_pollers!([endpoint], &DateTime.utc_now/0, limits)
          Process.sleep(ms)
        end)

      lines = log |> String.split("\n") |> Enum.filter(&(&1 =~ "alavi poller 127.0.0.1:#{port}"))
      {lines, port}
    end

    test "logs the bytes of noise before RTU replies, with endpoint and unit" do
      limits = %{max_frame_bytes: 64, max_lines: 100, window_ms: 60_000}
      {lines, port} = poll!(:rtu_over_tcp, [noise: <<0xFF, 0xFE>>], limits, 300)
      assert [line | _] = lines

      assert line =~
               "[warning] alavi poller 127.0.0.1:#{port} unit 1: 2 bytes skipped before the reply (noise): FF FE"
    end

    test "logs the corrupted frame when RTU replies fail their CRC" do
      limits = %{max_frame_bytes: 32, max_lines: 100, window_ms: 60_000}
      {lines, _port} = poll!(:rtu_over_tcp, [bad_crc: true], limits, 300)
      assert [line | _] = lines

      # The first read of each round is the identity check: the 25 registers 0-24, cut at 32 bytes.
      assert line =~
               ~r/unit 1: 55 bytes skipped before the reply \(bad CRC.*\): 01 03 32( [0-9A-F]{2}){29} \(first 32 shown\)$/
    end

    test "holds the cap: max_lines per window, then a count of what was suppressed" do
      limits = %{max_frame_bytes: 1, max_lines: 3, window_ms: 200}
      {lines, _port} = poll!(:rtu_over_tcp, [noise: <<0xFF, 0xFE>>], limits, 700)
      {summaries, hex} = Enum.split_with(lines, &(&1 =~ "suppressed"))

      assert [_ | _] = summaries
      assert Enum.all?(hex, &(&1 =~ ": FF (first 1 shown)"))
      # Never more than max_lines between one summary and the next.
      lines
      |> Enum.chunk_by(&(&1 =~ "suppressed"))
      |> Enum.reject(&(hd(&1) =~ "suppressed"))
      |> Enum.each(&assert(length(&1) <= 3))

      assert length(hex) <= 3 * (length(summaries) + 1)
    end
  end
end
