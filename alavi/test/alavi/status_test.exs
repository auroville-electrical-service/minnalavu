defmodule Alavi.StatusTest do
  use ExUnit.Case, async: true

  import Alavi.PollerCase
  import ExUnit.CaptureLog

  alias Alavi.{Buffer, Clock, ClockCheckFixture, FirmwareRead, MissedRead, Reading, Status}
  alias Alavi.Status.Snapshot

  @moduletag :tmp_dir
  @now ~U[2026-11-14 10:00:00Z]
  @at ~U[2026-11-14 09:59:00.123Z]
  @settings [{"log.dir", "C:\\alavi\\log"}, {"status.port", 8502}]

  defp config,
    do: config!([endpoint(5020, "tcp", [meter(1, "elite_440"), meter(3, "elite_440")])])

  defp snapshot, do: Snapshot.new(config(), @settings, "0.1.0", @now)

  defp reading(unit, key, value) do
    %Reading{
      endpoint: %{host: "127.0.0.1", port: 5020},
      unit_id: unit,
      meter_serial: "SIM-#{unit}",
      product_code: "ELITE440-445",
      profile: "elite_440",
      profile_version: 1,
      register_key: key,
      timestamp: @at,
      value: Decimal.new(value)
    }
  end

  defp missed(unit, key, reason, attempts \\ 3) do
    %MissedRead{
      endpoint: %{host: "127.0.0.1", port: 5020},
      unit_id: unit,
      meter_serial: nil,
      profile: "elite_440",
      profile_version: 1,
      register_key: key,
      timestamp: @at,
      reason: reason,
      attempts: attempts,
      raw_words: nil
    }
  end

  defp meter_view(snapshot, unit),
    do: snapshot.endpoints |> hd() |> Map.fetch!(:meters) |> Enum.find(&(&1.unit_id == unit))

  describe "Snapshot.new/4" do
    test "every configured endpoint and meter, with its registers' units and sources, unread" do
      snapshot = snapshot()

      assert %{version: "0.1.0", started_at: "2026-11-14T10:00:00Z", buffer: nil, uplink: nil} =
               snapshot

      assert snapshot.settings == [
               %{key: "log.dir", value: "C:\\alavi\\log"},
               %{key: "status.port", value: 8502}
             ]

      assert snapshot.clock == %{source: "unsynced", last_sync_at: nil}

      assert [%{host: "127.0.0.1", port: 5020, framing: "tcp", rounds: [], failures: []}] =
               snapshot.endpoints

      meter = meter_view(snapshot, 1)
      assert %{serial_expected: "SIM-1", serial: nil, last_read_at: nil, missed_reads: 0} = meter

      assert %{unit: "kWh", source: "elite_440-a", placeholder: false, value: nil} =
               Enum.find(meter.registers, &(&1.key == "active_energy_import"))
    end
  end

  describe "Snapshot.round/2" do
    test "readings set each meter's values as decimal strings, and the serial and code read" do
      snapshot =
        Snapshot.round(snapshot(), [
          reading(1, "active_energy_import", "123456.000"),
          reading(1, "active_energy_export", "0.500")
        ])

      meter = meter_view(snapshot, 1)

      assert %{
               serial: "SIM-1",
               product_code: "ELITE440-445",
               last_read_at: "2026-11-14T09:59:00.123Z"
             } =
               meter

      assert Enum.map(meter.registers, &{&1.key, &1.value}) == [
               {"active_energy_import", "123456.000"},
               {"active_energy_export", "0.500"}
             ]

      assert [%{at: "2026-11-14T09:59:00.123Z", units: [%{unit_id: 1, outcome: "ok"}]}] =
               hd(snapshot.endpoints).rounds
    end

    test "outcomes per unit, failures with their kind, and missed reads counted" do
      snapshot =
        Snapshot.round(snapshot(), [
          reading(1, "active_energy_import", "1"),
          missed(1, "active_energy_export", {:exception, 2}),
          missed(3, "active_energy_import", :timeout),
          missed(3, "active_energy_export", :timeout, 0)
        ])

      [endpoint] = snapshot.endpoints

      assert hd(endpoint.rounds).units == [
               %{unit_id: 1, outcome: "partial", reason: "exception"},
               %{unit_id: 3, outcome: "missed", reason: "timeout"}
             ]

      assert [
               %{
                 unit_id: 3,
                 register_key: "active_energy_export",
                 reason: "timeout",
                 attempts: 0
               },
               %{unit_id: 3, register_key: "active_energy_import", reason: "timeout"},
               %{unit_id: 1, reason: "exception", exception_code: 2, detail: nil}
             ] = endpoint.failures

      assert meter_view(snapshot, 1).missed_reads == 1
      assert meter_view(snapshot, 3).missed_reads == 2
      assert meter_view(snapshot, 3).serial == nil
    end

    test "rounds and failures are bounded rings, newest first" do
      rounds = for n <- 1..30, do: [missed(3, "active_energy_import", :timeout, n)]
      snapshot = Enum.reduce(rounds, snapshot(), &Snapshot.round(&2, &1))
      [endpoint] = snapshot.endpoints

      assert length(endpoint.rounds) == 10
      assert length(endpoint.failures) == 20
      assert hd(endpoint.failures).attempts == 30
      assert meter_view(snapshot, 3).missed_reads == 30
    end

    test "events from an endpoint not in the config change nothing" do
      event = %{
        reading(1, "active_energy_import", "1")
        | endpoint: %{host: "10.9.9.9", port: 502}
      }

      assert Snapshot.round(snapshot(), [event]) == snapshot()
    end
  end

  describe "Snapshot.on_demand/2" do
    test "sets the meters' values and failures as a round does, but adds no round" do
      snapshot =
        Snapshot.on_demand(snapshot(), [
          reading(1, "active_energy_import", "42.000"),
          missed(1, "active_energy_export", :timeout)
        ])

      [endpoint] = snapshot.endpoints
      assert endpoint.rounds == []
      assert [%{unit_id: 1, register_key: "active_energy_export"}] = endpoint.failures

      meter = meter_view(snapshot, 1)
      assert %{serial: "SIM-1", missed_reads: 1} = meter
      assert hd(meter.registers).value == "42.000"
    end

    test "leaves the last round as it was" do
      round = Snapshot.round(snapshot(), [missed(3, "active_energy_import", :timeout)])
      after_read = Snapshot.on_demand(round, [reading(1, "active_energy_import", "1")])
      assert hd(after_read.endpoints).rounds == hd(round.endpoints).rounds
    end
  end

  describe "Snapshot.firmware/2" do
    defp names(unit, endpoint \\ %{host: "127.0.0.1", port: 5020}) do
      %FirmwareRead{
        endpoint: endpoint,
        unit_id: unit,
        meter_serial: "SIM-#{unit}",
        product_code: "ELITE440-445",
        timestamp: @at,
        software: "SIM-SW",
        firmware_1: "SIM-F1",
        firmware_2: nil,
        modbus_version: "0100"
      }
    end

    test "sets the meter's names as last read, and only that meter's" do
      snapshot = Snapshot.firmware(snapshot(), names(3))

      assert meter_view(snapshot, 3).firmware == %{
               read_at: "2026-11-14T09:59:00.123Z",
               software: "SIM-SW",
               firmware_1: "SIM-F1",
               firmware_2: nil,
               modbus_version: "0100"
             }

      assert meter_view(snapshot, 1).firmware == nil
    end

    test "names from an endpoint or unit not in the config change nothing" do
      assert Snapshot.firmware(snapshot(), names(1, %{host: "10.9.9.9", port: 502})) ==
               snapshot()

      assert Snapshot.firmware(snapshot(), names(7)) == snapshot()
    end
  end

  describe "Snapshot.latency/3" do
    @endpoint %{host: "127.0.0.1", port: 5020}
    @summary %{
      since: ~D[2026-11-08],
      answered: 1_440,
      retries: 2,
      timeouts: 3,
      p50: 40,
      p90: 50,
      p99: 80,
      max: 75
    }

    test "sets each meter's latency, with its first day as a date string" do
      snapshot = Snapshot.latency(snapshot(), @endpoint, %{1 => @summary, 3 => nil})

      assert meter_view(snapshot, 1).latency == %{@summary | since: "2026-11-08"}
      assert meter_view(snapshot, 3).latency == nil
      json = snapshot |> Snapshot.to_json() |> JSON.decode!()

      assert %{"since" => "2026-11-08", "p99" => 80} =
               hd(hd(json["endpoints"])["meters"])["latency"]
    end

    test "an endpoint or unit not in the config changes nothing" do
      assert Snapshot.latency(snapshot(), %{host: "10.9.9.9", port: 502}, %{1 => @summary}) ==
               snapshot()

      assert Snapshot.latency(snapshot(), @endpoint, %{7 => @summary}) == snapshot()
    end
  end

  describe "Snapshot.selectors/4" do
    test "nil until reported, then the endpoint's last selector state, with why and when" do
      endpoint = %{host: "127.0.0.1", port: 5020}
      assert hd(snapshot().endpoints).selectors == nil

      owed =
        Snapshot.selectors(snapshot(), endpoint, {:owed, "{:read, :history, :timeout}", 3}, @now)

      assert hd(owed.endpoints).selectors == %{
               state: "owed",
               detail: "{:read, :history, :timeout}",
               at: "2026-11-14T10:00:00Z",
               attempts: 3
             }

      assert %{state: "restored", detail: nil, attempts: 0} =
               hd(Snapshot.selectors(owed, endpoint, :restored, @now).endpoints).selectors

      assert %{state: "refused", detail: "moved"} =
               hd(Snapshot.selectors(owed, endpoint, {:refused, "moved"}, @now).endpoints).selectors
    end

    test "an endpoint not in the config changes nothing" do
      assert Snapshot.selectors(snapshot(), %{host: "10.9.9.9", port: 502}, :restored, @now) ==
               snapshot()
    end
  end

  describe "Snapshot.raw_lines/3" do
    test "lines are kept newest first, at most 50" do
      snapshot = Snapshot.raw_lines(snapshot(), ["first", "second"], @now)

      assert [%{line: "second", at: "2026-11-14T10:00:00Z"}, %{line: "first"}] =
               snapshot.raw_lines

      lines = for n <- 1..60, do: "line #{n}"
      snapshot = Snapshot.raw_lines(snapshot, lines, @now)
      assert length(snapshot.raw_lines) == 50
      assert hd(snapshot.raw_lines).line == "line 60"
    end
  end

  describe "Snapshot.uplink/4" do
    test "the last attempt, its result, and when the next one is due" do
      snapshot = Snapshot.uplink(snapshot(), {:not_sent, "b-1", "HTTP 503: busy"}, 4_000, @now)

      assert snapshot.uplink == %{
               last_attempt_at: "2026-11-14T10:00:00Z",
               result: "not_sent",
               batch_id: "b-1",
               detail: "HTTP 503: busy",
               next_attempt_at: "2026-11-14T10:00:04.000Z"
             }

      assert %{result: "empty", batch_id: nil} = Snapshot.uplink(snapshot, :empty, 0, @now).uplink
      assert %{result: "stored"} = Snapshot.uplink(snapshot, {:stored, "b-1"}, 0, @now).uplink
    end
  end

  describe "Snapshot.config/2" do
    test "none until the keeper reports; then as a batch's backlog carries it" do
      assert snapshot().config == nil
      report = %{digest: String.duplicate("a", 64), refused: nil}

      assert Snapshot.config(snapshot(), report).config ==
               %{"digest" => report.digest, "refused_digest" => nil, "reason" => nil}
    end
  end

  describe "Snapshot.polling/2" do
    test "an endpoint kept keeps its history and its unchanged meters; the rest start afresh" do
      read =
        snapshot()
        |> Snapshot.round([
          reading(1, "active_energy_import", "5"),
          reading(3, "active_energy_import", "7")
        ])
        |> Snapshot.selectors(%{host: "127.0.0.1", port: 5020}, :restored, @now)

      changed =
        config!([
          endpoint(5021, "tcp", [meter(2, "elite_440")]),
          endpoint(5020, "rtu_over_tcp", [
            meter(1, "elite_440"),
            meter(3, "elite_500", %{"serial" => "SIM-3"}),
            meter(4, "elite_440")
          ])
        ])

      assert [%{port: 5021, rounds: [], meters: [%{unit_id: 2, last_read_at: nil}]}, kept] =
               Snapshot.polling(read, changed).endpoints

      assert %{framing: "rtu_over_tcp", rounds: [_round], selectors: %{state: "restored"}} = kept
      assert [one, three, four] = kept.meters
      assert one == meter_view(read, 1)
      assert %{unit_id: 3, profile: "elite_500", last_read_at: nil} = three
      assert %{unit_id: 4, last_read_at: nil} = four
    end

    test "an endpoint the config no longer has goes; another serial expected starts a meter afresh" do
      read = Snapshot.round(snapshot(), [reading(1, "active_energy_import", "5")])

      assert [
               %{
                 port: 5020,
                 meters: [%{unit_id: 1, serial_expected: "OTHER-1", last_read_at: nil}]
               }
             ] =
               Snapshot.polling(
                 read,
                 config!([
                   endpoint(5020, "tcp", [meter(1, "elite_440", %{"serial" => "OTHER-1"})])
                 ])
               ).endpoints

      assert [%{port: 5022}] =
               Snapshot.polling(read, config!([endpoint(5022, "tcp", [meter(1, "elite_440")])])).endpoints
    end
  end

  describe "Snapshot.clock/2" do
    test "the clock's source and last sync" do
      status = %{source: :ntp, last_sync_at: ~U[2026-11-14 09:00:00Z]}

      assert Snapshot.clock(snapshot(), status).clock ==
               %{source: "ntp", last_sync_at: "2026-11-14T09:00:00Z"}
    end
  end

  describe "Snapshot.clock_check/2" do
    test "none until a check; then its query, and the offset an answer implies" do
      assert snapshot().clock_check == nil

      # ((t2 - t1) + (t3 - t4)) / 2 = (4214.880051 + 4183.170312) / 2 s, toward zero.
      assert Snapshot.clock_check(snapshot(), ClockCheckFixture.answered()).clock_check == %{
               at: "2026-11-01T00:00:04.000123Z",
               trigger: "daily",
               server: "pool.ntp.org",
               outcome: "answered",
               address: "192.0.2.123",
               stratum: 2,
               offset_ms: 4199
             }
    end

    test "a failed check shows no offset; a kiss-o'-death its address" do
      timeout = Snapshot.clock_check(snapshot(), ClockCheckFixture.failed(:timeout)).clock_check
      assert %{outcome: "timeout", address: nil, stratum: nil, offset_ms: nil} = timeout

      kiss = Snapshot.clock_check(snapshot(), ClockCheckFixture.kiss_of_death()).clock_check
      assert %{outcome: "kiss_of_death", address: "2001:db8::7b", offset_ms: nil} = kiss
    end

    test "the offset rounds toward zero, negative too" do
      %{outcome: {:answered, a}} = check = ClockCheckFixture.answered()
      t1 = DateTime.to_unix(check.t1, :nanosecond)
      t4 = DateTime.to_unix(check.t4, :nanosecond)
      behind = %{check | outcome: {:answered, %{a | t2: t1 - 1_999_999, t3: t4 - 1_999_999}}}
      assert Snapshot.clock_check(snapshot(), behind).clock_check.offset_ms == -1
    end
  end

  describe "Snapshot.backlog/3" do
    test "the buffer's backlog as on the wire, or nil when the buffer did not answer" do
      backlog = %{
        events: 4,
        bytes: 900,
        batches: 2,
        oldest: @at,
        max_bytes: 1000,
        refused: 0,
        discarded_files: 0,
        quarantined: 1
      }

      assert %{as_of: "2026-11-14T10:00:00Z", backlog: %{"oldest" => "2026-11-14T09:59:00.123Z"}} =
               Snapshot.backlog(snapshot(), backlog, @now).buffer

      assert Snapshot.backlog(snapshot(), :unavailable, @now).buffer ==
               %{as_of: "2026-11-14T10:00:00Z", backlog: nil}
    end
  end

  describe "Snapshot.to_json/1" do
    test "the snapshot as JSON, with its format named" do
      snapshot = Snapshot.round(snapshot(), [reading(1, "active_energy_import", "1.250")])
      json = snapshot |> Snapshot.to_json() |> JSON.decode!()

      assert %{"format" => "alavi-status.v1", "version" => "0.1.0"} = json
      [meter | _] = hd(json["endpoints"])["meters"]
      assert hd(meter["registers"])["value"] == "1.250"

      owed = Snapshot.selectors(snapshot, %{host: "127.0.0.1", port: 5020}, :restored, @now)
      json = owed |> Snapshot.to_json() |> JSON.decode!()

      assert %{"state" => "restored", "at" => "2026-11-14T10:00:00Z"} =
               hd(json["endpoints"])["selectors"]
    end
  end

  defp start_buffer!(dir) do
    name = :"buffer_#{System.unique_integer([:positive])}"

    opts = [
      dir: Path.join(dir, "buffer"),
      max_bytes: 1_000_000,
      max_batch_events: 100,
      clock_status: &Clock.unsynced/0,
      name: name
    ]

    start_supervised!({Buffer, opts})
    name
  end

  defp start_status!(dir, buffer, tick_ms \\ 20) do
    name = :"status_#{System.unique_integer([:positive])}"

    opts = [
      config: config(),
      settings: @settings,
      version: "0.1.0",
      buffer: buffer,
      file: Path.join(dir, "status.json"),
      clock: fn -> @now end,
      tick_ms: tick_ms,
      name: name
    ]

    {start_supervised!({Status, opts}), name}
  end

  describe "start_link/1" do
    test "asks the buffer for its backlog, and writes the snapshot to its file", %{tmp_dir: dir} do
      buffer = start_buffer!(dir)
      :ok = Buffer.record(buffer, [reading(1, "active_energy_import", "1")])
      {_pid, status} = start_status!(dir, buffer)
      file = Path.join(dir, "status.json")

      :ok = eventually!(fn -> File.exists?(file) end)

      assert %{"buffer" => %{"backlog" => %{"events" => 1}}} =
               file |> File.read!() |> JSON.decode!()

      Status.round(status, [reading(3, "active_energy_import", "7")])

      :ok =
        eventually!(fn ->
          json = file |> File.read!() |> JSON.decode!()
          Enum.any?(hd(json["endpoints"])["meters"], &(&1["serial"] == "SIM-3"))
        end)

      refute File.exists?(file <> ".tmp")
    end

    test "a buffer that is down shows as not answering, and the status goes on", %{tmp_dir: dir} do
      {pid, status} = start_status!(dir, :no_such_buffer)
      :ok = eventually!(fn -> Status.read(status).buffer != nil end)
      assert %{backlog: nil} = Status.read(status).buffer
      assert Process.alive?(pid)
    end

    test "a file it cannot write is logged once, and the status goes on", %{tmp_dir: dir} do
      log =
        capture_log(fn ->
          {pid, status} = start_status!(Path.join(dir, "missing"), :no_such_buffer)
          Process.sleep(100)
          assert %Snapshot{} = Status.read(status)
          assert Process.alive?(pid)
        end)

      assert [_one] = Regex.scan(~r/alavi status: cannot write .*status\.json/, log)
    end
  end

  describe "read/1" do
    test "returns the current snapshot", %{tmp_dir: dir} do
      {_pid, status} = start_status!(dir, :no_such_buffer, 60_000)
      assert %Snapshot{version: "0.1.0", settings: [_, _]} = Status.read(status)
    end
  end

  describe "feeds" do
    test "casts update the snapshot", %{tmp_dir: dir} do
      {_pid, status} = start_status!(dir, :no_such_buffer, 60_000)

      Status.round(status, [reading(1, "active_energy_import", "5")])
      Status.raw_lines(status, ["alavi poller 127.0.0.1:5020 unit 1: reply rejected"])
      Status.uplink(status, {:stored, "b-1"}, 0)
      Status.clock(status, %{source: :rtc, last_sync_at: nil})
      Status.config(status, %{digest: String.duplicate("a", 64), refused: nil})
      Status.clock_check(status, ClockCheckFixture.failed(:timeout))
      Status.latency(status, %{host: "127.0.0.1", port: 5020}, %{3 => @summary})
      Status.selectors(status, %{host: "127.0.0.1", port: 5020}, {:owed, "found at start", 0})
      snapshot = Status.read(status)
      Status.polling(status, config!([endpoint(5021, "tcp", [meter(1, "elite_440")])]))
      assert [%{port: 5021}] = Status.read(status).endpoints

      assert meter_view(snapshot, 1).serial == "SIM-1"
      assert [%{line: "alavi poller " <> _}] = snapshot.raw_lines
      assert %{result: "stored", batch_id: "b-1"} = snapshot.uplink
      assert snapshot.clock.source == "rtc"
      assert snapshot.config["digest"] == String.duplicate("a", 64)
      assert snapshot.clock_check.outcome == "timeout"
      assert meter_view(snapshot, 3).latency.p99 == 80
      assert hd(snapshot.endpoints).selectors.state == "owed"
    end

    test "a read on demand updates its meters, not the rounds", %{tmp_dir: dir} do
      {_pid, status} = start_status!(dir, :no_such_buffer, 60_000)

      Status.on_demand(status, [reading(3, "active_energy_import", "5")])
      snapshot = Status.read(status)

      assert meter_view(snapshot, 3).serial == "SIM-3"
      assert hd(snapshot.endpoints).rounds == []
      assert :ok = Status.on_demand(status, [])
    end

    test "a cast to a status that is not running is dropped" do
      assert :ok = Status.round(Alavi.NoStatus, [reading(1, "active_energy_import", "5")])
      assert :ok = Status.raw_lines(Alavi.NoStatus, ["line"])
      assert :ok = Status.uplink(Alavi.NoStatus, :empty, 0)
      assert :ok = Status.clock(Alavi.NoStatus, Clock.unsynced())
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, _, _, _}
      assert :ok = Status.clock(dead, Clock.unsynced())
    end
  end

  describe "Supervisor.start_link/1" do
    test "starts the status and its page, which restart on their own", %{tmp_dir: dir} do
      opts = [
        status: [
          config: config(),
          settings: @settings,
          version: "0.1.0",
          buffer: :no_such_buffer,
          file: Path.join(dir, "status.json"),
          clock: fn -> @now end,
          tick_ms: 60_000,
          name: :"status_#{System.unique_integer([:positive])}"
        ],
        port: 0
      ]

      sup = start_supervised!({Status.Supervisor, opts})
      children = Supervisor.which_children(sup)
      {Status, first, :worker, _} = List.keyfind(children, Status, 0)
      {Status.Web, web, :supervisor, _} = List.keyfind(children, Status.Web, 0)
      Process.exit(first, :kill)

      :ok =
        eventually!(fn ->
          match?(
            {Status, pid, _, _} when is_pid(pid) and pid != first,
            List.keyfind(Supervisor.which_children(sup), Status, 0)
          )
        end)

      assert {Status.Web, ^web, _, _} =
               List.keyfind(Supervisor.which_children(sup), Status.Web, 0)

      port = web_port(web)
      {:ok, conn} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
      :ok = :gen_tcp.send(conn, "GET / HTTP/1.1\r\nHost: localhost:#{port}\r\n\r\n")
      assert {:ok, "HTTP/1.1 200 OK" <> _} = :gen_tcp.recv(conn, 0, 5_000)
    end

    test "a status that cannot start is logged, and ignored", %{tmp_dir: dir} do
      Process.flag(:trap_exit, true)
      opts = [status: [file: Path.join(dir, "status.json"), name: :no_status], port: 0]

      log = capture_log(fn -> assert :ignore = Status.Supervisor.start_link(opts) end)
      assert log =~ "collecting goes on without it"
    end
  end
end
