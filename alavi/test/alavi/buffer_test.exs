defmodule Alavi.BufferTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import ExUnit.CaptureLog

  alias Alavi.{Buffer, Clock, ClockCheckFixture, FirmwareRead, MissedRead, Reading}
  alias Alavi.Buffer.Batch

  @moduletag :tmp_dir
  @keys ["active_energy_import", "active_energy_export", "reactive_energy_import"]

  defp start!(dir, opts \\ []) do
    name = :"buffer_#{System.unique_integer([:positive])}"

    base = [
      dir: dir,
      max_bytes: 1_000_000,
      max_batch_events: 1_000,
      clock_status: &Clock.unsynced/0,
      name: name
    ]

    start_supervised!({Buffer, Keyword.merge(base, opts)}, id: :buffer)
    name
  end

  defp restart!(dir, opts \\ []) do
    :ok = stop_supervised(:buffer)
    start!(dir, opts)
  end

  defp reading(unit_id, key, value, ts) do
    %Reading{
      endpoint: %{host: "127.0.0.1", port: 5020},
      unit_id: unit_id,
      meter_serial: "SIM-#{unit_id}",
      product_code: "ELITE440-445",
      profile: "elite_440",
      profile_version: 1,
      register_key: key,
      timestamp: ts,
      value: Decimal.new(value)
    }
  end

  defp meter(unit_id, ts \\ ~U[2026-11-01 00:00:00Z]),
    do: Enum.map(@keys, &reading(unit_id, &1, "#{unit_id}.5", ts))

  # Every batch, oldest first, each acknowledged once taken.
  defp drain(buffer) do
    case Buffer.take(buffer) do
      {:ok, batch} ->
        :ok = Buffer.ack(buffer, batch.id)
        [batch | drain(buffer)]

      :empty ->
        []
    end
  end

  defp units(events), do: events |> Enum.map(& &1.unit_id) |> Enum.dedup()

  defp segments(dir), do: dir |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".seg"))

  describe "record/2" do
    @describetag :capture_log

    test "batches hold at most max_batch_events, in recorded order", %{tmp_dir: dir} do
      buffer = start!(dir, max_batch_events: 6)
      for unit <- 1..5, do: :ok = Buffer.record(buffer, meter(unit))

      assert buffer |> drain() |> Enum.map(&units(&1.events)) == [[1, 2], [3, 4], [5]]
    end

    test "a change of clock status starts a new batch", %{tmp_dir: dir} do
      synced = %{source: :ntp, last_sync_at: ~U[2026-11-01 00:00:00.123Z]}
      {:ok, status} = Agent.start_link(fn -> Clock.unsynced() end)
      buffer = start!(dir, clock_status: fn -> Agent.get(status, & &1) end)

      :ok = Buffer.record(buffer, meter(1))
      Agent.update(status, fn _ -> synced end)
      :ok = Buffer.record(buffer, meter(2))
      :ok = Buffer.record(buffer, meter(3))

      {:ok, first} = Buffer.take(buffer)
      assert %{clock: %{source: :unsynced}, events: [%{unit_id: 1} | _]} = first
      :ok = Buffer.ack(buffer, first.id)
      buffer = restart!(dir)
      assert {:ok, %Batch{clock: ^synced, events: events}} = Buffer.take(buffer)
      assert units(events) == [2, 3]
    end

    test "missed reads are kept with their reason", %{tmp_dir: dir} do
      buffer = start!(dir)

      missed = %MissedRead{
        endpoint: %{host: "127.0.0.1", port: 5020},
        unit_id: 2,
        meter_serial: "SIM-2",
        profile: "elite_440",
        profile_version: 1,
        register_key: "active_energy_import",
        timestamp: ~U[2026-11-01 00:00:00.000001Z],
        reason: {:unreachable, {:socket, :econnrefused}},
        attempts: 0,
        raw_words: nil
      }

      decode = %{missed | reason: {:decode, :not_finite}, raw_words: [0x7FC0, 0], attempts: 1}
      :ok = Buffer.record(buffer, [missed, decode])
      assert {:ok, %Batch{events: [^missed, ^decode]}} = Buffer.take(restart!(dir))
    end

    property "values, profile versions and timestamps come back exactly as recorded",
             %{tmp_dir: dir} do
      buffer = start!(dir)

      check all coef <- integer(0..999_999_999_999),
                version <- integer(1..9_007_199_254_740_991),
                exp <- integer(-6..0),
                sign <- member_of([1, -1]),
                precision <- integer(0..6),
                digits <- integer(0..(10 ** precision - 1)),
                max_runs: 50 do
        value = %Decimal{sign: sign, coef: coef, exp: exp}
        usec = digits * 10 ** (6 - precision)
        ts = %{~U[2026-11-01 00:00:00Z] | microsecond: {usec, precision}}

        event = %{
          reading(1, "active_energy_import", "0", ts)
          | value: value,
            profile_version: version
        }

        :ok = Buffer.record(buffer, [event])
        {:ok, batch} = Buffer.take(buffer)
        :ok = Buffer.ack(buffer, batch.id)
        assert batch.events == [event]
        assert Enum.map(batch.events, &Reading.to_wire/1) == [Reading.to_wire(event)]
      end
    end

    test "a full buffer refuses new events, counts them and keeps what it has", %{tmp_dir: dir} do
      buffer = start!(dir, max_bytes: 600, max_batch_events: 4)

      results = for unit <- 1..20, do: Buffer.record(buffer, meter(unit))
      kept = Enum.count(results, &(&1 == :ok))
      assert kept > 0 and kept < 20
      assert Enum.drop(results, kept) |> Enum.all?(&(&1 == {:error, :full}))

      backlog = Buffer.backlog(buffer)
      assert backlog.bytes <= 600
      assert backlog.refused == (20 - kept) * 3
      assert backlog.events == kept * 3

      log =
        capture_log(fn ->
          {:ok, batch} = Buffer.take(buffer)
          :ok = Buffer.ack(buffer, batch.id)
          assert :ok = Buffer.record(buffer, meter(21))
        end)

      assert log =~ "accepting events again"

      events = buffer |> drain() |> Enum.flat_map(& &1.events)
      assert units(events) == Enum.to_list(2..kept) ++ [21]
    end

    test "becoming full is logged as an error once", %{tmp_dir: dir} do
      buffer = start!(dir, max_bytes: 300)

      log =
        capture_log(fn -> for unit <- 1..20, do: Buffer.record(buffer, meter(unit)) end)

      assert [_] = Regex.scan(~r/\[error\].*full at 300 bytes/, log)
    end

    test "a failed write keeps nothing of the call and counts its events as refused",
         %{tmp_dir: dir} do
      buffer = start!(dir)
      File.write!(Path.join(dir, "00000000000000000000.seg"), "in the way")

      assert {:error, {:write, :eexist}} = Buffer.record(buffer, meter(1))
      assert %{events: 0, refused: 3} = Buffer.backlog(buffer)
      assert :ok = Buffer.record(buffer, meter(2))
      assert {:ok, %Batch{events: events}} = Buffer.take(buffer)
      assert events == meter(2)
    end
  end

  describe "take/1" do
    test "recorded events are taken as a batch and gone once acknowledged", %{tmp_dir: dir} do
      buffer = start!(dir)
      assert Buffer.take(buffer) == :empty
      assert :ok = Buffer.record(buffer, meter(1))
      assert :ok = Buffer.record(buffer, meter(2))

      assert {:ok, %Batch{id: id, events: events, clock: clock}} = Buffer.take(buffer)
      assert events == meter(1) ++ meter(2)
      assert clock == Clock.unsynced()
      assert id =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

      assert :ok = Buffer.ack(buffer, id)
      assert Buffer.take(buffer) == :empty
      assert %{events: 0, bytes: 0, batches: 0, oldest: nil} = Buffer.backlog(buffer)
      assert segments(dir) == []
      assert {:error, :unknown_batch} = Buffer.ack(buffer, id)
    end

    test "an unacknowledged batch is offered again, also after a restart", %{tmp_dir: dir} do
      buffer = start!(dir)
      :ok = Buffer.record(buffer, meter(1))
      {:ok, batch} = Buffer.take(buffer)
      assert Buffer.take(buffer) == {:ok, batch}

      buffer = restart!(dir)
      assert Buffer.take(buffer) == {:ok, batch}

      # Events recorded after a restart go into a new batch, after the old one.
      :ok = Buffer.record(buffer, meter(2))
      :ok = Buffer.ack(buffer, batch.id)
      assert {:ok, %Batch{events: events}} = Buffer.take(buffer)
      assert events == meter(2)
    end
  end

  describe "heartbeat/1" do
    test "an empty batch with a new id each time and the clock now, never on disk",
         %{tmp_dir: dir} do
      synced = %{source: :ntp, last_sync_at: ~U[2026-11-01 00:00:00Z]}
      buffer = start!(dir, clock_status: fn -> synced end)

      assert %Batch{id: first, clock: ^synced, events: []} = Buffer.heartbeat(buffer)
      assert %Batch{id: second} = Buffer.heartbeat(buffer)
      assert first != second and first =~ ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4/
      assert Buffer.take(buffer) == :empty
      assert segments(dir) == []
    end
  end

  describe "ack/2" do
    test "batches can be acknowledged out of order", %{tmp_dir: dir} do
      buffer = start!(dir, max_batch_events: 3)
      for unit <- 1..3, do: :ok = Buffer.record(buffer, meter(unit))
      buffer = restart!(dir)

      {:ok, first} = Buffer.take(buffer)
      :ok = Buffer.ack(buffer, first.id)
      {:ok, second} = Buffer.take(buffer)
      # The uplink may hold on to `second` and acknowledge `third` first.
      :ok = Buffer.ack(buffer, second.id)
      assert {:ok, %Batch{events: [%{unit_id: 3} | _]}} = Buffer.take(buffer)
    end
  end

  describe "backlog/1" do
    test "backlog reports events, bytes, batches and the oldest timestamp", %{tmp_dir: dir} do
      buffer = start!(dir, max_batch_events: 3)
      :ok = Buffer.record(buffer, meter(1, ~U[2026-11-02 00:00:00Z]))
      :ok = Buffer.record(buffer, meter(2, ~U[2026-11-01 00:00:00Z]))

      backlog = Buffer.backlog(buffer)

      assert %{events: 6, batches: 2, oldest: ~U[2026-11-01 00:00:00Z], max_bytes: 1_000_000} =
               backlog

      assert backlog.bytes ==
               dir |> segments() |> Enum.map(&File.stat!(Path.join(dir, &1)).size) |> Enum.sum()

      assert Buffer.backlog(restart!(dir)) == backlog
    end

    @tag :capture_log
    test "discarded and quarantined files do not count towards bytes", %{tmp_dir: dir} do
      buffer = start!(dir, max_batch_events: 3)
      for unit <- 1..2, do: :ok = Buffer.record(buffer, meter(unit))
      {:ok, first} = Buffer.take(buffer)
      :ok = Buffer.quarantine(buffer, first.id, "rejected")
      :ok = stop_supervised(:buffer)
      [seg] = segments(dir)
      File.write!(Path.join(dir, seg), "not a record", [:append])

      backlog = Buffer.backlog(start!(dir))
      assert %{discarded_files: 1, quarantined: 1, batches: 1} = backlog
      assert backlog.bytes == File.stat!(Path.join(dir, seg)).size
    end
  end

  describe "quarantine/3" do
    @describetag :capture_log

    test "a quarantined batch is moved aside with its reason, and the next one offered",
         %{tmp_dir: dir} do
      buffer = start!(dir, max_batch_events: 3)
      for unit <- 1..2, do: :ok = Buffer.record(buffer, meter(unit))
      {:ok, first} = Buffer.take(buffer)

      log =
        capture_log(fn ->
          assert :ok = Buffer.quarantine(buffer, first.id, "HTTP 422 PT422: batch rejected")
        end)

      assert log =~ "[error]" and log =~ first.id and log =~ "quarantine"
      assert {:ok, %Batch{events: [%{unit_id: 2} | _]}} = Buffer.take(buffer)
      assert %{batches: 1, events: 3, quarantined: 1} = Buffer.backlog(buffer)

      quarantine = Path.join(dir, "quarantine")
      [segment] = segments(quarantine)
      assert File.read!(Path.join(quarantine, segment <> ".reason")) =~ "PT422"
      assert segments(dir) |> length() == 1
      assert Buffer.quarantine(buffer, first.id, "again") == {:error, :unknown_batch}
    end

    test "quarantined batches are counted after a restart and their names never reused",
         %{tmp_dir: dir} do
      buffer = start!(dir)
      :ok = Buffer.record(buffer, meter(1))
      {:ok, first} = Buffer.take(buffer)
      :ok = Buffer.quarantine(buffer, first.id, "rejected")

      buffer = restart!(dir)
      assert %{quarantined: 1, batches: 0} = Buffer.backlog(buffer)
      :ok = Buffer.record(buffer, meter(2))
      assert segments(dir) != segments(Path.join(dir, "quarantine"))

      # Moved back by hand, a quarantined batch is offered again, unchanged.
      :ok = stop_supervised(:buffer)
      [name] = segments(Path.join(dir, "quarantine"))
      File.rename!(Path.join([dir, "quarantine", name]), Path.join(dir, name))
      buffer = start!(dir)
      assert {:ok, ^first} = Buffer.take(buffer)
    end
  end

  describe "start_link/1" do
    @describetag :capture_log

    test "a torn tail is set aside and the records before it kept", %{tmp_dir: dir} do
      buffer = start!(dir)
      for unit <- 1..3, do: :ok = Buffer.record(buffer, meter(unit))
      :ok = stop_supervised(:buffer)
      [seg] = segments(dir)
      path = Path.join(dir, seg)
      %{size: size} = File.stat!(path)
      torn = binary_part(File.read!(path), 0, size - 5)
      :ok = File.write(path, torn)

      buffer = start!(dir)
      assert {:ok, %Batch{events: events}} = Buffer.take(buffer)
      assert events == meter(1) ++ meter(2)
      assert %{discarded_files: 1, events: 6} = Buffer.backlog(buffer)
      assert File.read!(path) <> File.read!(path <> ".discarded") == torn
    end

    test "garbage after the last record is set aside", %{tmp_dir: dir} do
      buffer = start!(dir)
      for unit <- 1..2, do: :ok = Buffer.record(buffer, meter(unit))
      :ok = stop_supervised(:buffer)
      [seg] = segments(dir)
      File.write!(Path.join(dir, seg), <<0, 0, 0, 9, "not a record">>, [:append])

      buffer = start!(dir)
      assert {:ok, %Batch{events: events}} = Buffer.take(buffer)
      assert events == meter(1) ++ meter(2)
      assert %{discarded_files: 1} = Buffer.backlog(buffer)
      # The cut-back segment parses cleanly from now on.
      assert %{discarded_files: 1, events: 6} = Buffer.backlog(restart!(dir))
    end

    test "a record whose checksum fails is set aside with what follows it", %{tmp_dir: dir} do
      buffer = start!(dir)
      for unit <- 1..3, do: :ok = Buffer.record(buffer, meter(unit))
      :ok = stop_supervised(:buffer)
      [seg] = segments(dir)
      path = Path.join(dir, seg)
      data = File.read!(path)
      last = :binary.last(data)
      File.write!(path, binary_part(data, 0, byte_size(data) - 1) <> <<Bitwise.bxor(last, 1)>>)

      buffer = start!(dir)
      assert {:ok, %Batch{events: events}} = Buffer.take(buffer)
      assert events == meter(1) ++ meter(2)
      assert %{discarded_files: 1} = Buffer.backlog(buffer)
    end

    test "a segment with no valid header is set aside, an empty one removed", %{tmp_dir: dir} do
      buffer = start!(dir)
      :ok = Buffer.record(buffer, meter(1))
      :ok = stop_supervised(:buffer)
      File.write!(Path.join(dir, "00000000000000000007.seg"), "ALAVI")
      File.write!(Path.join(dir, "00000000000000000008.seg"), "")

      log = capture_log(fn -> start!(dir) end)
      assert log =~ "no valid header"
      assert File.exists?(Path.join(dir, "00000000000000000007.seg.discarded"))
      refute File.exists?(Path.join(dir, "00000000000000000008.seg"))
    end

    test "a segment in an earlier format is set aside, not decoded", %{tmp_dir: dir} do
      buffer = start!(dir)
      :ok = Buffer.record(buffer, meter(1))
      :ok = stop_supervised(:buffer)

      # A reading as format 4 wrote it: raw words and unit, no profile version.
      reading =
        {:reading, "127.0.0.1", 5020, 2, "SIM-2", "ELITE440-445", "elite_440",
         "active_energy_import", "2026-11-01T00:00:00Z", [0x4700, 0x0000], {1, 25, -1}, "Wh", nil}

      paths =
        for version <- 1..4 do
          path = Path.join(dir, "0000000000000000000#{version + 4}.seg")
          segment = <<"ALAVIBUF", version>> <> frame({<<version::128>>, {:unsynced, nil}})
          File.write!(path, segment <> frame([reading]))
          path
        end

      log = capture_log(fn -> send(self(), {:buffer, start!(dir)}) end)
      assert_received {:buffer, buffer}
      assert log =~ "no valid header"
      assert Enum.all?(paths, &File.exists?(&1 <> ".discarded"))
      assert %{discarded_files: 4, events: 3} = Buffer.backlog(buffer)
    end

    test "a request id is kept with its reading and missed read, across a restart",
         %{tmp_dir: dir} do
      id = "7d2c1f0e-4b3a-4c5d-8e6f-1a2b3c4d5e6f"

      read = %{
        reading(1, "active_energy_import", "1.5", ~U[2026-11-01 00:00:00Z])
        | request_id: id
      }

      missed = %MissedRead{
        endpoint: %{host: "127.0.0.1", port: 5020},
        unit_id: 2,
        meter_serial: "SIM-2",
        profile: "elite_440",
        profile_version: 1,
        register_key: "active_energy_import",
        timestamp: ~U[2026-11-01 00:00:01Z],
        reason: :timeout,
        attempts: 3,
        raw_words: nil,
        request_id: id
      }

      buffer = start!(dir)
      :ok = Buffer.record(buffer, meter(3))
      :ok = Buffer.record(buffer, [read, missed])
      buffer = restart!(dir)

      assert {:ok, %Batch{events: events}} = Buffer.take(buffer)
      assert events == meter(3) ++ [read, missed]
      assert Enum.map(events, & &1.request_id) == [nil, nil, nil, id, id]
    end

    test "a firmware read is kept with the readings, across a restart", %{tmp_dir: dir} do
      names = %FirmwareRead{
        endpoint: %{host: "127.0.0.1", port: 5020},
        unit_id: 1,
        meter_serial: "SIM-1",
        product_code: "ELITE440-445",
        timestamp: ~U[2026-11-01 00:00:00.123456Z],
        software: "SIM-SW",
        firmware_1: nil,
        firmware_2: "SIM-F2",
        modbus_version: "0100"
      }

      buffer = start!(dir)
      :ok = Buffer.record(buffer, meter(1))
      :ok = Buffer.record(buffer, [names])
      buffer = restart!(dir)

      assert {:ok, %Batch{events: events}} = Buffer.take(buffer)
      assert List.last(events) == names
      assert Enum.drop(events, -1) == meter(1)
    end

    test "clock checks of every outcome are kept, across a restart", %{tmp_dir: dir} do
      checks =
        [ClockCheckFixture.answered(), ClockCheckFixture.kiss_of_death()] ++
          Enum.map([:timeout, :unreachable, :invalid], &ClockCheckFixture.failed/1)

      buffer = start!(dir)
      :ok = Buffer.record(buffer, checks)
      buffer = restart!(dir)

      assert {:ok, %Batch{events: ^checks}} = Buffer.take(buffer)
      assert Buffer.backlog(buffer).oldest == ~U[2026-11-01 00:00:04.000123Z]
    end
  end

  defp frame(term) do
    payload = :erlang.term_to_binary(term, [:compressed])
    <<byte_size(payload)::32, :erlang.crc32(payload)::32, payload::binary>>
  end
end
