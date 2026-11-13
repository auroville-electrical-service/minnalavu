defmodule Alavi.Clock.W32tmTest do
  use ExUnit.Case, async: true

  alias Alavi.Clock.W32tm

  # These samples are NOT from a real machine. They are written from the
  # documented shape of `w32tm /query /status /verbose` on an English
  # Windows, with invented addresses and times. The parser is unverified
  # against real output until it has run on Windows.
  @now ~U[2026-11-11 10:00:00Z]

  defp sample(source, leap, extra) do
    """
    Leap Indicator: #{leap}
    Stratum: 3 (secondary reference - syncd by (S)NTP)
    Precision: -23 (119.209ns per tick)
    Root Delay: 0.0312500s
    Root Dispersion: 7.7766762s
    ReferenceId: 0xC0A80101 (source IP:  192.0.2.1)
    Last Successful Sync Time: 11/11/2026 3:25:12 PM
    Source: #{source}
    Poll Interval: 10 (1024s)

    Phase Offset: 0.0001234s
    ClockRate: 0.0156250s
    State Machine: 2 (Sync)
    Time Source Flags: 0 (None)
    Server Role: 0 (None)
    Last Sync Error: 0 (The command completed successfully.)
    #{extra}
    """
    |> String.replace("\n", "\r\n")
  end

  defp ntp(source, since \\ "Time since Last Good Sync Time: 312.4560000s"),
    do: sample(source, "0(no warning)", since)

  describe "parse/2" do
    test "an NTP peer is ntp, last synced the time since before now" do
      assert {:ok, %{source: :ntp, last_sync_at: ~U[2026-11-11 09:54:47Z]}} =
               W32tm.parse(ntp("time.windows.com,0x9"), @now)
    end

    test "a peer by address, IPv4 or IPv6, or a domain controller is ntp" do
      for source <- ["192.0.2.1", "192.0.2.1,0x8", "fe80::1", "dc01.example.org"] do
        assert {:ok, %{source: :ntp}} = W32tm.parse(ntp(source), @now), source
      end
    end

    test "a whole number of seconds since the last sync parses too" do
      assert {:ok, %{last_sync_at: ~U[2026-11-11 09:59:00Z]}} =
               W32tm.parse(ntp("192.0.2.1", "Time since Last Good Sync Time: 60s"), @now)
    end

    test "the local CMOS clock is rtc, with no last sync" do
      assert {:ok, %{source: :rtc, last_sync_at: nil}} =
               W32tm.parse(ntp("Local CMOS Clock"), @now)
    end

    test "a free-running clock is unsynced" do
      output = sample("Free-running System Clock", "3(not synchronized)", "")
      assert {:ok, %{source: :unsynced, last_sync_at: nil}} = W32tm.parse(output, @now)
    end

    test "an NTP peer that is not synchronised is unsynced" do
      output = sample("192.0.2.1", "3(not synchronized)", "")
      assert {:ok, %{source: :unsynced, last_sync_at: nil}} = W32tm.parse(output, @now)
    end

    test "output in another display language is not recognised" do
      # Invented German labels: the point is only that they are not English.
      output = """
      Sprungindikator: 0(keine Warnung)
      Stratum: 3 (Sekundärreferenz - synchr. über (S)NTP)
      Letzte erfolgreiche Synchronisierungszeit: 11.11.2026 15:25:12
      Quelle: time.windows.com,0x9
      Zeit seit der letzten erfolgreichen Synchronisierung: 312.4560000s
      """

      assert {:error, :unrecognised} = W32tm.parse(output, @now)
    end

    test "anything else not recognised is an error, never a guess" do
      for output <- [
            "",
            "The following error occurred: The service has not been started. (0x80070426)",
            ntp("VM IC Time Synchronization Provider"),
            ntp("time.windows.com", ""),
            ntp("time.windows.com", "Time since Last Good Sync Time: soon"),
            String.replace(ntp("192.0.2.1"), "Leap Indicator: 0", "Leap Indicator: x")
          ] do
        assert {:error, :unrecognised} = W32tm.parse(output, @now), inspect(output)
      end
    end
  end

  describe "settle/2" do
    @synced %{source: :ntp, last_sync_at: ~U[2026-11-11 09:54:47Z]}

    test "keeps the previous status for the same sync, give or take 2 s" do
      assert W32tm.settle(@synced, %{@synced | last_sync_at: ~U[2026-11-11 09:54:49Z]}) == @synced
      assert W32tm.settle(@synced, %{@synced | last_sync_at: ~U[2026-11-11 09:54:45Z]}) == @synced
    end

    test "takes a later sync, or another source" do
      later = %{@synced | last_sync_at: ~U[2026-11-11 10:12:00Z]}
      assert W32tm.settle(@synced, later) == later

      assert W32tm.settle(@synced, %{source: :rtc, last_sync_at: nil}) == %{
               source: :rtc,
               last_sync_at: nil
             }
    end
  end
end
