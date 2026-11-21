defmodule Alavi.EndToEndTest do
  @moduledoc """
  Simulator -> pollers -> buffer -> uplink -> PostgREST -> database, with the
  rows checked in the database. Needs the end-to-end store, never the dev
  store: `central/bin/e2e-db`, see CLAUDE.md. Excluded from `mix test` and
  `mix check`; run with `bin/dev alavi mix test --only e2e`.
  """

  use ExUnit.Case, async: false

  import Alavi.PollerCase

  alias Alavi.{
    Buffer,
    Clock,
    Collector,
    Config,
    Decode,
    FakeNtp,
    MeterClockRead,
    StoredEntry,
    Uplink,
    Wire
  }

  alias Alavi.Config.{Digest, Saved}
  alias Alavi.Uplink.{HTTP, Target}
  alias Simulator.Meter

  @moduletag :e2e
  @moduletag :tmp_dir
  @moduletag :capture_log
  @collector_at ~U[2026-11-01 00:00:04.000123Z]
  @server_at 1_793_491_208_215_003_051
  @token_script Path.expand("../../../central/bin/collector-token", __DIR__)

  defp env!(name), do: System.fetch_env!(name)

  # Runs SQL as the database owner and decodes its single JSON result.
  defp sql!(query) do
    {out, 0} =
      System.cmd(
        "psql",
        [env!("MINNALAVU_E2E_DB_URL"), "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1"] ++
          ["-c", query]
      )

    JSON.decode!(out)
  end

  defp rows!(query), do: sql!("SELECT coalesce(json_agg(t), '[]') FROM (#{query}) t")

  defp collector!(id) do
    role = "collector_" <> id
    ^role = sql!("SELECT to_json(admin.create_collector('#{id}'))")

    # The copy window of `Alavi.PollerCase.document/1`, so a local config can match the served one.
    sql!("""
    SELECT to_json(admin.set_copy_window(collector_id => '#{id}', valid_from => '2026-01-01Z',
      start_time => '02:00', end_time => '03:00'))
    """)

    {token, 0} = System.cmd("bash", [@token_script, id, "1"])
    String.trim(token)
  end

  defp start_collector!(
         dir,
         endpoints,
         token,
         named \\ [],
         clock \\ &DateTime.utc_now/0,
         keeper \\ :none
       ),
       do:
         start_supervised!(
           {Collector, collector_opts(dir, config!(endpoints), token, clock, keeper) ++ named}
         )

  defp target!(token) do
    {:ok, target} =
      Target.parse(env!("MINNALAVU_E2E_API_URL"), token, allow_http: true, cacerts: [])

    target
  end

  defp collector_opts(dir, config, token, clock, keeper) do
    buffer = [
      dir: dir,
      max_bytes: 1_000_000,
      max_batch_events: 1_000,
      clock_status: &Clock.unsynced/0,
      name: Buffer
    ]

    uplink = [
      target: target!(token),
      clock: &DateTime.utc_now/0,
      idle_ms: 50,
      backoff_ms: %{min: 50, max: 500},
      timeout_ms: 5_000
    ]

    [
      config: config,
      buffer: buffer,
      clock: clock,
      uplink: uplink,
      config_keeper: keeper,
      raw_log: raw_log(),
      clock_status: :none,
      clock_check: :none,
      status: no_status()
    ]
  end

  defp await!(what, check, tries \\ 200) do
    cond do
      check.() -> :ok
      tries > 0 -> Process.sleep(50) && await!(what, check, tries - 1)
      true -> flunk("never happened: #{what}")
    end
  end

  test "readings from the simulator land in the database, exactly, under the token's collector",
       ctx do
    # Random, not unique_integer: collector roles outlive the database.
    id = "e2e_#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}"
    token = collector!(id)

    {sim, port} = start_sim!(:tcp, missing_units: :gateway_error)
    # What the meters report, not what the config expects, is what gets stored.
    read_serial = String.upcase(id)
    :ok = Simulator.identify(sim, 3, :serial, read_serial)

    meters = [
      meter(1, "elite_440", %{"serial" => "CFG-1"}),
      meter(9, "elite_440", %{"serial" => "CFG-9"}),
      Map.delete(meter(3, "elite_500"), "serial")
    ]

    start_collector!(ctx.tmp_dir, [endpoint(port, "tcp", meters)], token)

    count = fn table ->
      sql!("SELECT count(*) FROM store.#{table} WHERE collector_id = '#{id}'")
    end

    await!("6 readings, 2 missed reads and 2 firmware reads stored", fn ->
      count.("readings") >= 6 and count.("missed_reads") >= 2 and
        count.("firmware_reads") >= 2
    end)

    await!("the buffer emptied", fn -> Buffer.backlog(Buffer).events == 0 end)

    readings =
      rows!("""
      SELECT r.meter_serial, r.product_code, r.register_key, r.value::text AS value,
             p.unit::text AS unit, r.unit_id
      FROM store.readings r
      JOIN store.profile_registers p
        ON (p.profile, p.version, p.register_key) = (r.profile, r.profile_version, r.register_key)
      WHERE r.collector_id = '#{id}'
      """)

    by_key = Map.new(readings, &{{&1["meter_serial"], &1["register_key"]}, &1})
    # Floats as the shortest decimal that round-trips at their width (ADR 0020).
    assert by_key[{"SIM-1", "active_energy_import"}]["value"] == "123456"
    assert by_key[{read_serial, "active_energy_import"}]["value"] == "1234.5"
    # The unit comes from the profile version's catalog row, not the reading.
    assert by_key[{"SIM-1", "active_energy_import"}]["unit"] == "kWh"

    assert readings
           |> Enum.map(&{&1["meter_serial"], &1["product_code"]})
           |> Enum.uniq()
           |> Enum.sort() ==
             Enum.sort([{"SIM-1", "ELITE440-445"}, {read_serial, "E500C-5102"}])

    # Import and export are separate rows, never a net figure.
    assert Map.has_key?(by_key, {"SIM-1", "active_energy_export"})
    assert length(readings) == 6

    missed =
      rows!("""
      SELECT meter_serial, unit_id, reason::text AS reason, exception_code
      FROM store.missed_reads WHERE collector_id = '#{id}'
      """)

    # Unit 9 never answered, so no serial was read for it.
    assert Enum.all?(
             missed,
             &match?(
               %{
                 "unit_id" => 9,
                 "meter_serial" => nil,
                 "reason" => "exception",
                 "exception_code" => 11
               },
               &1
             )
           )

    names =
      rows!("""
      SELECT meter_serial, product_code, unit_id, software, firmware_1, firmware_2, modbus_version
      FROM store.firmware_reads WHERE collector_id = '#{id}' ORDER BY unit_id
      """)

    # Unit 9 gave no serial, so it has no names record; the others' names as the meters report.
    assert [
             %{"unit_id" => 1, "meter_serial" => "SIM-1", "product_code" => "ELITE440-445"},
             %{"unit_id" => 3, "meter_serial" => ^read_serial, "product_code" => "E500C-5102"}
           ] = names

    assert Enum.all?(
             names,
             &match?(
               %{
                 "software" => "SIM-SW",
                 "firmware_1" => "SIM-F1",
                 "firmware_2" => "SIM-F2",
                 "modbus_version" => "0100"
               },
               &1
             )
           )

    [upload | _] =
      rows!("""
      SELECT b.clock_source::text AS clock, u.backlog_events, u.backlog_max_bytes
      FROM store.uploads u JOIN store.batches b USING (batch_id)
      WHERE u.collector_id = '#{id}' ORDER BY u.upload_id
      """)

    assert %{"clock" => "unsynced", "backlog_max_bytes" => 1_000_000} = upload
    assert upload["backlog_events"] >= 1
  end

  defp new_collector! do
    # Random, not unique_integer: collector roles outlive the database.
    id = "e2e_#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}"
    {id, collector!(id)}
  end

  test "a request made through jobs.request_job is read by the collector and answered", ctx do
    {id, token} = new_collector!()
    {sim, port} = start_sim!(:tcp)
    serial = String.upcase(id)
    :ok = Simulator.identify(sim, 3, :serial, serial)

    # The registry knows the unit as a target and the meter there by the serial it reports;
    # the polling config expects none.
    sql!("""
    SELECT to_json(admin.register_endpoint(
      endpoint_id => '#{id}_ep', valid_from => '2026-01-01Z', collector_id => '#{id}',
      host => '127.0.0.1', port => #{port}, framing => 'tcp', polled_by_other_system => false,
      timeout_ms => 100, max_timeouts => 3, retries => 2, busy_backoff_ms => 10,
      reconnect_backoff_min_ms => 10, reconnect_backoff_max_ms => 40, interval_ms => 1500, retry_ms => 60000))
    """)

    sql!("""
    SELECT to_json(admin.register_target(endpoint_id => '#{id}_ep', unit_id => 3,
      valid_from => '2026-01-01Z', profile => 'elite_500', interval_ms => NULL, retry_ms => NULL))
    """)

    sql!("""
    SELECT to_json(admin.register_meter(serial => '#{serial}', valid_from => '2026-01-01Z',
      endpoint_id => '#{id}_ep', unit_id => 3))
    """)

    meters = [meter(1, "elite_440"), Map.delete(meter(3, "elite_500"), "serial")]
    endpoints = [endpoint(port, "tcp", meters, %{"interval_ms" => 1_500})]
    start_collector!(ctx.tmp_dir, endpoints, token, pollers: Alavi.Pollers)

    count = fn -> sql!("SELECT count(*) FROM store.readings WHERE collector_id = '#{id}'") end
    await!("the first round stored", fn -> count.() >= 6 end)

    request =
      sql!("""
      SET ROLE minkanakku_staff;
      SELECT to_json(jobs.request_job(collector_id => '#{id}', kind => 'read_on_demand',
        meters => ARRAY['#{serial}'], requester => 'e2e'))
      """)

    status = fn ->
      [row] =
        rows!("""
        SELECT state::text AS state, readings, missed_reads, meters
        FROM jobs.request_status WHERE request_id = '#{request}'
        """)

      row
    end

    await!("the request answered", fn -> status.()["state"] == "answered" end)
    # Every reading of the read is linked: all of the meter's registers.
    await!("the read's 4 readings linked", fn -> status.()["readings"] == 4 end)
    assert %{"missed_reads" => 0, "meters" => [^serial]} = status.()

    linked =
      rows!("""
      SELECT l.meter_serial, l.register_key, r.unit_id, r.value::text AS value
      FROM jobs.request_readings l
      JOIN store.readings r ON r.collector_id = '#{id}' AND r.meter_serial = l.meter_serial
        AND r.register_key = l.register_key AND r.read_at = l.read_at
      WHERE l.request_id = '#{request}'
      """)

    assert length(linked) == 4
    assert Enum.all?(linked, &match?(%{"meter_serial" => ^serial, "unit_id" => 3}, &1))

    # Listed in no answer once answered, and run once: no more linked as rounds go on.
    Process.sleep(3_500)
    assert status.()["readings"] == 4
  end

  # A buffer and an uplink with no pollers: what is stored is what the test records.
  defp start_uplink!(dir, id, token) do
    target = target!(token)
    buffer = :"buffer_#{id}"

    start_supervised!(
      {Buffer,
       dir: dir,
       max_bytes: 1_000_000,
       max_batch_events: 1_000,
       clock_status: &Clock.unsynced/0,
       name: buffer}
    )

    start_supervised!(
      {Uplink,
       buffer: buffer,
       target: target,
       clock: &DateTime.utc_now/0,
       idle_ms: 50,
       heartbeat_ms: 100,
       intake: :none,
       config: :none,
       backoff_ms: %{min: 50, max: 500},
       timeout_ms: 5_000,
       status: no_status()}
    )

    buffer
  end

  test "a heartbeat is stored as an upload of nothing", ctx do
    {id, token} = new_collector!()
    start_uplink!(ctx.tmp_dir, id, token)

    uploads = fn ->
      rows!("""
      SELECT u.readings_inserted, u.missed_reads_inserted, u.backlog_events,
             b.clock_source::text AS clock
      FROM store.uploads u JOIN store.batches b USING (batch_id)
      WHERE u.collector_id = '#{id}'
      """)
    end

    await!("two heartbeats stored", fn -> length(uploads.()) >= 2 end)

    assert Enum.all?(
             uploads.(),
             &match?(
               %{
                 "readings_inserted" => 0,
                 "missed_reads_inserted" => 0,
                 "backlog_events" => 0,
                 "clock" => "unsynced"
               },
               &1
             )
           )
  end

  # The collector's clock reads `@collector_at` until the fake server takes the
  # query, and 300 µs later from then on: t1 and t4 are known exactly.
  defp start_check!(buffer, servers, respond) do
    {:ok, clock} = Agent.start_link(fn -> @collector_at end)

    answer = fn request ->
      Agent.update(clock, &DateTime.add(&1, 300, :microsecond))
      respond.(request)
    end

    port = FakeNtp.start!(answer)

    start_supervised!(
      {Clock.Check,
       servers: servers,
       port: port,
       sink: {Buffer, buffer},
       status: no_status(),
       clock: fn -> Agent.get(clock, & &1) end,
       monotonic: fn -> System.monotonic_time(:millisecond) end,
       timeout_ms: 200,
       watch_ms: 60_000,
       step_ms: 2_000,
       day_ms: 86_400_000,
       step_gap_ms: 600_000}
    )
  end

  test "an answered clock check is stored, and its offset computed exactly from its four times",
       ctx do
    {id, token} = new_collector!()
    buffer = start_uplink!(ctx.tmp_dir, id, token)
    sent = @server_at + 41_001

    start_check!(
      buffer,
      ["127.0.0.1"],
      &{:reply, FakeNtp.reply(&1, received: @server_at, sent: sent)}
    )

    offsets = fn ->
      rows!("""
      SELECT (t1 AT TIME ZONE 'UTC')::text AS t1, (t4 AT TIME ZONE 'UTC')::text AS t4, t2_unix::text AS t2, t3_unix::text AS t3, offset_seconds::text AS offset,
             delay_seconds::text AS delay, error_bound_seconds::text AS bound,
             server, host(address) AS address, stratum, leap, trigger::text AS trigger
      FROM store.clock_offsets WHERE collector_id = '#{id}'
      """)
    end

    await!("the check stored", fn -> offsets.() != [] end)

    # t2 − t1 = 4.214880051 s and t3 − t4 = 4.214621052 s, to the nanosecond.
    assert [
             %{
               "t1" => "2026-11-01 00:00:04.000123",
               "t4" => "2026-11-01 00:00:04.000423",
               "t2" => "1793491208.215003051",
               "t3" => "1793491208.215044052",
               "offset" => "4.2147505515",
               "delay" => "0.000258999",
               "bound" => "0.0001294995",
               "server" => "127.0.0.1",
               "address" => "127.0.0.1",
               "stratum" => 2,
               "leap" => 0,
               "trigger" => "start"
             }
           ] = offsets.()
  end

  test "a clock check no server answered is stored with its outcome", ctx do
    {id, token} = new_collector!()
    buffer = start_uplink!(ctx.tmp_dir, id, token)
    start_check!(buffer, ["127.0.0.1"], fn _ -> :drop end)

    checks = fn ->
      rows!("""
      SELECT (t1 AT TIME ZONE 'UTC')::text AS t1, outcome::text AS outcome, t2_unix, address
      FROM store.clock_checks WHERE collector_id = '#{id}'
      """)
    end

    await!("the check stored", fn -> checks.() != [] end)

    assert [
             %{
               "t1" => "2026-11-01 00:00:04.000123",
               "outcome" => "timeout",
               "t2_unix" => nil,
               "address" => nil
             }
           ] = checks.()

    assert sql!("SELECT count(*) FROM store.clock_offsets WHERE collector_id = '#{id}'") == 0
  end

  # Every reply 301 ms late: each answer lands in the (300, 400] ms bucket,
  # with 99 ms to spare for a loaded machine and far inside the timeout, so
  # every percentile is that bucket's bound cut to the exact max.
  test "a meter's latency for a day is stored when the day ends, and its percentiles computed exactly",
       ctx do
    {id, token} = new_collector!()
    {sim, port} = start_sim!(:tcp)
    Simulator.faults(sim, delay_ms: 301)
    # The database keeps earlier runs' readings until it is recreated, and a
    # fixed clock would repeat them.
    :ok = Simulator.identify(sim, 1, :serial, String.upcase(id))
    {:ok, clock} = Agent.start_link(fn -> ~U[2026-11-13 23:59:59Z] end)

    endpoints = [
      endpoint(port, "tcp", [meter(1, "elite_440")], %{"interval_ms" => 5, "timeout_ms" => 2_000})
    ]

    start_collector!(ctx.tmp_dir, endpoints, token, [], fn -> Agent.get(clock, & &1) end)

    readings = fn ->
      sql!("SELECT count(*) FROM store.readings WHERE collector_id = '#{id}'")
    end

    await!("a round's readings stored", fn -> readings.() >= 2 end)
    Agent.update(clock, fn _ -> ~U[2026-11-14 00:00:01Z] end)

    days = fn ->
      rows!("""
      SELECT endpoint_host, endpoint_port, unit_id, day::text AS day,
             (poller_started_at AT TIME ZONE 'UTC')::text AS started, buckets_version, retries,
             timeouts, max_ms, buckets
      FROM store.latency_days WHERE collector_id = '#{id}'
      """)
    end

    await!("the day's latency stored", fn -> days.() != [] end)

    assert [
             %{
               "endpoint_host" => "127.0.0.1",
               "endpoint_port" => ^port,
               "unit_id" => 1,
               "day" => "2026-11-13",
               "started" => "2026-11-13 23:59:59",
               "buckets_version" => 1,
               "retries" => 0,
               "timeouts" => 0,
               "max_ms" => max,
               "buckets" => buckets
             }
           ] = days.()

    answered = Enum.sum(buckets)
    assert length(buckets) == 44 and answered > 0
    assert Enum.at(buckets, 23) == answered, "every answer in the (300, 400] ms bucket"
    assert max > 300 and max <= 400

    assert [
             %{
               "answered" => ^answered,
               "p50_ms" => ^max,
               "p90_ms" => ^max,
               "p99_ms" => ^max,
               "max_ms" => ^max
             }
           ] =
             rows!("""
             SELECT answered, p50_ms, p90_ms, p99_ms, max_ms
             FROM store.latency_meter_days WHERE collector_id = '#{id}'
             """)
  end

  test "a registry change is fetched, saved and reported; one the collector cannot parse is refused, raised in health",
       ctx do
    {id, token} = new_collector!()
    {_sim, port} = start_sim!(:tcp)
    endpoints = [endpoint(port, "tcp", [meter(1, "elite_440")], %{"interval_ms" => 300})]
    {:ok, local} = Digest.digest(document(endpoints))

    sql!("""
    SELECT to_json(admin.register_endpoint(
      endpoint_id => '#{id}_ep', valid_from => '2026-01-01Z', collector_id => '#{id}',
      host => '127.0.0.1', port => #{port}, framing => 'tcp', polled_by_other_system => false,
      timeout_ms => 100, max_timeouts => 3, retries => 2, busy_backoff_ms => 10,
      reconnect_backoff_min_ms => 10, reconnect_backoff_max_ms => 40, interval_ms => 300, retry_ms => 60000))
    """)

    sql!("""
    SELECT to_json(admin.register_target(endpoint_id => '#{id}_ep', unit_id => 1,
      valid_from => '2026-01-01Z', profile => 'elite_440', interval_ms => NULL, retry_ms => NULL))
    """)

    served = fn ->
      sql!("SELECT to_json(registry.config_digest(registry.collector_config('#{id}')))")
    end

    first = served.()
    refute first == local

    keeper = [digest: local, profiles: profiles(), name: Alavi.ConfigKeeper]
    start_collector!(ctx.tmp_dir, endpoints, token, [], &DateTime.utc_now/0, keeper)

    reported = fn ->
      case rows!("""
           SELECT config_digest AS digest, config_refused_digest AS refused,
                  config_refusal_reason AS reason
           FROM store.uploads WHERE collector_id = '#{id}'
           ORDER BY received_at DESC, upload_id DESC LIMIT 1
           """) do
        [row] -> row
        [] -> nil
      end
    end

    saved = fn ->
      case Saved.read(ctx.tmp_dir) do
        {:ok, _path, document} -> document |> Digest.digest() |> elem(1)
        :none -> nil
      end
    end

    await!("the registry's config fetched, saved and reported", fn ->
      match?(%{"digest" => ^first, "refused" => nil}, reported.()) and saved.() == first
    end)

    sql!("""
    SELECT to_json(admin.change_target(endpoint_id => '#{id}_ep', unit_id => 1,
      valid_from => now(), profile => 'elite_440', interval_ms => 600, retry_ms => NULL))
    """)

    second = served.()
    refute second == first

    await!("the changed config fetched, saved and reported", fn ->
      match?(%{"digest" => ^second, "refused" => nil}, reported.()) and saved.() == second
    end)

    # A profile this collector has not loaded: the whole config is refused.
    sql!("""
    SELECT to_json(admin.change_target(endpoint_id => '#{id}_ep', unit_id => 1,
      valid_from => now(), profile => 'no_such_profile', interval_ms => 600, retry_ms => NULL))
    """)

    third = served.()

    await!("the refusal reported", fn ->
      match?(%{"digest" => ^second, "refused" => ^third}, reported.())
    end)

    assert reported.()["reason"] =~ "no_such_profile"
    assert saved.() == second

    assert [%{"detail" => detail}] =
             rows!("""
             SELECT detail FROM health.problems
             WHERE kind = 'config_refused' AND subject = '#{id}'
             """)

    assert detail =~ third and detail =~ second
  end

  defp register_endpoint!(id, name, port) do
    sql!("""
    SELECT to_json(admin.register_endpoint(
      endpoint_id => '#{id}_#{name}', valid_from => '2026-01-01Z', collector_id => '#{id}',
      host => '127.0.0.1', port => #{port}, framing => 'tcp', polled_by_other_system => false,
      timeout_ms => 100, max_timeouts => 3, retries => 2, busy_backoff_ms => 10,
      reconnect_backoff_min_ms => 10, reconnect_backoff_max_ms => 40, interval_ms => 300, retry_ms => 60000))
    """)
  end

  defp register_target!(id, name, unit, profile, valid_from \\ "'2026-01-01Z'") do
    sql!("""
    SELECT to_json(admin.register_target(endpoint_id => '#{id}_#{name}', unit_id => #{unit},
      valid_from => #{valid_from}, profile => '#{profile}', interval_ms => NULL, retry_ms => NULL))
    """)
  end

  test "a registry change reaches the running pollers: new endpoints polled, removed ones stopped, changed ones with their new settings",
       ctx do
    {id, token} = new_collector!()

    [kept, changed, removed, added] =
      for _ <- 1..4 do
        {sim, port} = start_sim!(:tcp)
        # Readings are keyed by serial: each chain's meters their own.
        for unit <- [1, 3] do
          serial = Base.encode16(:crypto.strong_rand_bytes(4))
          :ok = Simulator.identify(sim, unit, :serial, serial)
        end

        port
      end

    for {name, port} <- [kept: kept, changed: changed, removed: removed] do
      register_endpoint!(id, name, port)
      register_target!(id, name, 1, "elite_440")
    end

    local = [endpoint(kept, "tcp", [meter(1, "elite_440")], %{"interval_ms" => 300})]
    {:ok, digest} = Digest.digest(document(local))
    keeper = [digest: digest, profiles: profiles(), name: Alavi.ConfigKeeper]

    collector =
      start_collector!(
        ctx.tmp_dir,
        local,
        token,
        [pollers: Alavi.Pollers],
        &DateTime.utc_now/0,
        keeper
      )

    readings = fn port, unit ->
      sql!("""
      SELECT count(*) FROM store.readings
      WHERE collector_id = '#{id}' AND endpoint_port = #{port} AND unit_id = #{unit}
      """)
    end

    reported = fn ->
      sql!("""
      SELECT coalesce(to_json((SELECT config_digest FROM store.uploads
        WHERE collector_id = '#{id}' ORDER BY received_at DESC, upload_id DESC LIMIT 1)), 'null')
      """)
    end

    served = fn ->
      sql!("SELECT to_json(registry.config_digest(registry.collector_config('#{id}')))")
    end

    await!("the registry's endpoints polled", fn ->
      Enum.all?([kept, changed, removed], &(readings.(&1, 1) > 0))
    end)

    first = served.()
    await!("the registry's config reported", fn -> reported.() == first end)

    poller = fn port ->
      List.keyfind(Alavi.Pollers.pollers(Alavi.Pollers), {Alavi.Poller, "127.0.0.1", port}, 0)
    end

    {_id, kept_pid} = poller.(kept)
    {_id, changed_pid} = poller.(changed)

    sql!("""
    SELECT to_json(admin.retire_target(endpoint_id => '#{id}_removed', unit_id => 1, valid_from => now()));
    """)

    sql!(
      "SELECT to_json(admin.retire_endpoint(endpoint_id => '#{id}_removed', valid_from => now()))"
    )

    register_target!(id, "changed", 3, "elite_500", "now()")
    register_endpoint!(id, "added", added)
    register_target!(id, "added", 1, "elite_440")
    second = served.()
    refute second == first

    await!("the added endpoint and the changed one's new target polled", fn ->
      readings.(added, 1) > 0 and readings.(changed, 3) > 0
    end)

    await!("the changed config reported", fn -> reported.() == second end)
    await!("the removed endpoint's poller gone", fn -> poller.(removed) == nil end)
    await!("the buffer emptied", fn -> Buffer.backlog(Buffer).events == 0 end)
    stopped = readings.(removed, 1)
    Process.sleep(1_000)
    assert readings.(removed, 1) == stopped
    assert readings.(changed, 1) > 0
    assert {_id, ^kept_pid} = poller.(kept)
    assert {_id, pid} = poller.(changed)
    assert is_pid(pid) and pid != changed_pid
    assert Process.alive?(collector)
  end

  # The simulated meters' host clock starts here and runs at real speed, so
  # what they hold is known exactly. Their clocks are 1,725 s ahead (as .13's
  # was), at 09:35:45: the next load-survey interval ends minutes away, so
  # the intervals of the current day that have ended stay the same throughout.
  @sim_at ~U[2026-11-16 09:07:00Z]
  @meter_offset_s 1_725

  defp sim_clock do
    start = DateTime.to_unix(@sim_at, :millisecond)
    mono = System.monotonic_time(:millisecond)
    {start, fn -> start + System.monotonic_time(:millisecond) - mono end}
  end

  # Random, so no earlier run's entries share a key with this one's; 8 characters, as a 440 holds.
  defp serial, do: Base.encode16(:crypto.strong_rand_bytes(4))

  defp copying_meter(unit, profile, stores) do
    unit
    |> Meter.new(Simulator.Profile.load!(profile), %{
      "active_energy_import" => Decimal.new("123456.000")
    })
    |> Meter.clock(@meter_offset_s, 0)
    |> Meter.stores(stores)
  end

  # Starts the chain on the simulated clock; returns its port and the host time it started at.
  defp start_copy_chain!(meters) do
    {start, now} = sim_clock()
    {sim, port} = start_chain!(:tcp, Enum.map(meters, &elem(&1, 0)), now: now)

    for {meter, serial} <- meters,
        do: :ok = Simulator.identify(sim, meter.unit_id, :serial, serial)

    {sim, port, start}
  end

  # The collector's clock: real time, moved on by what `shift!` adds.
  defp shifted_clock! do
    {:ok, shift} = Agent.start_link(fn -> 0 end)
    {shift, fn -> DateTime.add(DateTime.utc_now(), Agent.get(shift, & &1)) end}
  end

  defp shift!(shift, seconds), do: Agent.update(shift, fn _ -> seconds end)

  # Open from ten minutes before the collector's local time to fifty after.
  defp window(utc) do
    at =
      utc
      |> DateTime.to_naive()
      |> NaiveDateTime.truncate(:second)
      |> NaiveDateTime.to_erl()
      |> :calendar.universal_time_to_local_time()
      |> NaiveDateTime.from_erl!()

    %{"start" => hhmm(NaiveDateTime.add(at, -600)), "end" => hhmm(NaiveDateTime.add(at, 3000))}
  end

  defp hhmm(at), do: at |> NaiveDateTime.to_time() |> Time.to_string() |> binary_part(0, 5)

  # A collector copying `endpoint`, its copy events cast to the test process.
  defp start_copying!(dir, endpoint, token, clock, changes) do
    document = Map.put(document([endpoint]), "copy_window", window(clock.()))
    {:ok, config} = Config.parse(document, profiles())
    opts = Keyword.merge(collector_opts(dir, config, token, clock, :none), changes)
    start_supervised!({Collector, Keyword.put(opts, :status, self())})
  end

  defp copy_ended!(port, outcome) do
    receive do
      {:"$gen_cast", {:copy, %{port: ^port}, {:finished, ^outcome}}} -> :ok
    after
      120_000 -> flunk("no copy ended: #{outcome}")
    end
  end

  # What the copy of `meter` must keep, computed from the simulator's own
  # model: {store, register_key, meter_time} => {value, interval_s}. Every
  # entry the meter holds of a quantity it supports and the profile names;
  # of the current day, each interval its clock has ended.
  defp held(meter, start) do
    meter = Meter.anchor(meter, start)
    blocks(meter, start) |> Map.merge(survey(meter, start))
  end

  defp blocks(meter, start) do
    stores = meter.stores

    for {store, slots} <- [
          history: 1..stores.histories//1,
          snapshot: 0..(stores.snapshots - 1)//1
        ],
        n <- slots,
        {:ok, %{stamp: at, values: values}} <- [Meter.stored(meter, store, n, start)],
        {key, %Decimal{} = value} <- values,
        into: %{},
        do: {{Atom.to_string(store), key, NaiveDateTime.to_string(at)}, {f32(value), nil}}
  end

  defp survey(meter, start) do
    now = Meter.time(meter, start)
    stores = meter.stores

    for n <- 0..(stores.days - 1)//1,
        %{number: number, key: key} <- meter.profile.stored.load_survey.parameters,
        MapSet.member?(stores.parameters, number),
        {:ok, %{stamp: day, interval: minutes, values: values}} <-
          [Meter.stored(meter, :load_survey, {n, number}, start)],
        {%Decimal{} = value, i} <- Enum.with_index(values),
        at <- [NaiveDateTime.add(day, i * minutes * 60)],
        not NaiveDateTime.after?(NaiveDateTime.add(at, minutes * 60), now),
        into: %{},
        do: {{"load_survey", key, NaiveDateTime.to_string(at)}, {f32(value), minutes * 60}}
  end

  # The simulator's value as the meter's f32 holds it, in the store's text.
  defp f32(value) do
    words = Simulator.Encode.words(%{type: :f32, word_order: :low_first, decimals: nil}, value)
    {:ok, decoded} = Decode.words(:f32, :low_first, nil, words)
    text(decoded)
  end

  defp text(%Decimal{} = d), do: d |> Decimal.normalize() |> Decimal.to_string(:normal)
  defp text(value) when is_binary(value), do: value |> Decimal.new() |> text()

  # As `role`: monitor has no rights on store, and reads copies through health.
  defp entries!(view, serial, role \\ "postgres") do
    sql!("""
    SET ROLE #{role};
    SELECT coalesce(json_agg(t), '[]') FROM (
      SELECT store::text AS store, register_key, meter_time::text AS at, value::text AS value,
             interval_s
      FROM #{view} WHERE meter_serial = '#{serial}') t
    """)
    |> Map.new(
      &{{&1["store"], &1["register_key"], &1["at"]}, {text(&1["value"]), &1["interval_s"]}}
    )
  end

  # Each copied entry's kind, as the store's catalog holds it for the entry's profile version.
  defp kinds!(serial) do
    rows!("""
    SELECT DISTINCT e.store::text AS store, e.register_key, p.kind::text AS kind,
           e.profile_version, e.product_code
    FROM store.stored_entries e
    JOIN store.profile_stored p
      ON (p.profile, p.version, p.store, p.register_key)
         = (e.profile, e.profile_version, e.store, e.register_key)
    WHERE e.meter_serial = '#{serial}'
    """)
  end

  # The kind the profile gives each quantity of each store.
  defp profile_kinds(name) do
    stored = profiles()[name].stored

    for {store, entries} <- [
          history: stored.history.registers,
          snapshot: stored.snapshot.registers,
          load_survey: stored.load_survey.parameters
        ],
        %{key: key, kind: kind} <- entries,
        into: %{},
        do: {{Atom.to_string(store), key}, Atom.to_string(kind)}
  end

  defp meter_clocks!(serial) do
    sql!("""
    SET ROLE monitor;
    SELECT coalesce(json_agg(t), '[]') FROM (
      SELECT meter_time::text AS at, profile, profile_version, unit_id
      FROM health.meter_clock_reads
      WHERE meter_serial = '#{serial}' AND received_at IS NOT NULL) t
    """)
  end

  defp upload_totals!(id) do
    [totals] =
      rows!("""
      SELECT sum(stored_entries_inserted) AS inserted, sum(stored_entries_duplicate) AS duplicate,
             sum(stored_entries_conflicting) AS conflicting,
             sum(meter_clock_reads_inserted) AS clocks
      FROM store.uploads WHERE collector_id = '#{id}'
      """)

    totals
  end

  defp count!(table, serial),
    do: sql!("SELECT count(*) FROM store.#{table} WHERE meter_serial = '#{serial}'")

  test "a 440's and a 500's copied entries land in the store exactly, kinds from the catalog, " <>
         "meter-clock reads beside them, and monitor reads both through health",
       ctx do
    {id, token} = new_collector!()
    {s440, s500} = {serial(), serial()}
    m440 = copying_meter(1, "elite_440", [])
    m500 = copying_meter(3, "elite_500", days: 2, snapshots: 3)
    {_sim, port, start} = start_copy_chain!([{m440, s440}, {m500, s500}])

    units = [
      meter(1, "elite_440", %{"serial" => s440}),
      meter(3, "elite_500", %{"serial" => s500})
    ]

    {_shift, clock} = shifted_clock!()
    start_copying!(ctx.tmp_dir, endpoint(port, "tcp", units, %{"copy" => true}), token, clock, [])

    copy_ended!(port, :done)
    await!("the buffer emptied", fn -> Buffer.backlog(Buffer).events == 0 end)

    for {meter, serial, profile, product} <- [
          {m440, s440, "elite_440", "ELITE440-445"},
          {m500, s500, "elite_500", "E500C-5102"}
        ] do
      held = held(meter, start)
      assert entries!("store.stored_entries", serial) == held

      kinds = profile_kinds(profile)
      rows = kinds!(serial)
      assert Enum.all?(rows, &(&1["kind"] == kinds[{&1["store"], &1["register_key"]}]))
      assert Enum.all?(rows, &match?(%{"profile_version" => 2, "product_code" => ^product}, &1))

      # Once riding the first round's names, then at the visit's start and end: the
      # meter's own clock, read within the test's run of its start.
      at_start = meter |> Meter.anchor(start) |> Meter.time(start)
      clocks = meter_clocks!(serial)
      assert length(clocks) == 3

      assert Enum.all?(clocks, fn %{"at" => at} = read ->
               read["profile"] == profile and read["profile_version"] == 2 and
                 NaiveDateTime.diff(NaiveDateTime.from_iso8601!(at), at_start) in 0..300
             end)

      # What was copied, and when it arrived, as monitor reads it.
      view = "(SELECT * FROM health.stored_entries WHERE received_at IS NOT NULL) e"
      assert entries!(view, serial, "monitor") == held
    end

    assert Enum.sort(Enum.uniq(for r <- kinds!(s440), do: {r["store"], r["kind"]})) == [
             {"history", "cumulative"},
             {"load_survey", "instantaneous"},
             {"load_survey", "interval"},
             {"snapshot", "cumulative"}
           ]

    rows = count!("stored_entries", s440) + count!("stored_entries", s500)

    assert %{"inserted" => ^rows, "duplicate" => 0, "conflicting" => 0, "clocks" => 6} =
             upload_totals!(id)
  end

  defp post!(target, batch) do
    body =
      batch |> Wire.batch(DateTime.utc_now(), Buffer.backlog(Buffer), :none) |> JSON.encode!()

    assert {:ok, status, _answer} = HTTP.post(target, body, 10_000)
    assert status in 200..299
  end

  # Sends every batch the buffer holds, as the uplink would, acknowledging each.
  defp drain!(target, sent \\ []) do
    case Buffer.take(Buffer) do
      {:ok, batch} ->
        post!(target, batch)
        :ok = Buffer.ack(Buffer, batch.id)
        drain!(target, [batch | sent])

      :empty ->
        Enum.reverse(sent)
    end
  end

  defp copied_in(batch), do: Enum.count(batch.events, &match?(%StoredEntry{}, &1))

  test "a copy's batches sent again, their acknowledgement lost, add nothing: " <>
         "every stored entry and meter-clock read a duplicate, counted on the upload",
       ctx do
    {id, token} = new_collector!()
    s440 = serial()
    m440 = copying_meter(1, "elite_440", [])
    {_sim, port, start} = start_copy_chain!([{m440, s440}])
    units = [meter(1, "elite_440", %{"serial" => s440})]
    {_shift, clock} = shifted_clock!()

    start_copying!(ctx.tmp_dir, endpoint(port, "tcp", units, %{"copy" => true}), token, clock,
      uplink: :none
    )

    copy_ended!(port, :done)
    target = target!(token)
    batches = drain!(target)
    held = held(m440, start)
    assert entries!("store.stored_entries", s440) == held
    assert Enum.sum_by(batches, &copied_in/1) == map_size(held)

    for batch <- batches, do: post!(target, batch)

    assert entries!("store.stored_entries", s440) == held
    assert count!("meter_clock_reads", s440) == 3

    uploads =
      rows!("""
      SELECT batch_id::text AS batch, stored_entries_inserted AS inserted,
             stored_entries_duplicate AS duplicate, stored_entries_conflicting AS conflicting,
             meter_clock_reads_inserted AS clocks, meter_clock_reads_duplicate AS clocks_again
      FROM store.uploads WHERE collector_id = '#{id}' ORDER BY upload_id
      """)

    for batch <- batches do
      n = copied_in(batch)
      clocks = Enum.count(batch.events, &match?(%MeterClockRead{}, &1))

      assert [
               %{"inserted" => ^n, "duplicate" => 0, "clocks" => ^clocks, "clocks_again" => 0},
               %{"inserted" => 0, "duplicate" => ^n, "clocks" => 0, "clocks_again" => ^clocks}
             ] = Enum.filter(uploads, &(&1["batch"] == batch.id))
    end

    assert Enum.all?(uploads, &(&1["conflicting"] == 0))
  end

  test "a copy the window closes on resumes the next night, and the store ends with every " <>
         "entry once, the re-copied ones counted as duplicates",
       ctx do
    {id, token} = new_collector!()
    s440 = serial()
    m440 = copying_meter(1, "elite_440", [])
    {sim, port, start} = start_copy_chain!([{m440, s440}])
    # Slow enough that the window can close mid-copy; polls often, so the closing is soon seen.
    Simulator.faults(sim, delay_ms: 20)
    units = [meter(1, "elite_440", %{"serial" => s440})]
    {shift, clock} = shifted_clock!()
    changes = %{"copy" => true, "interval_ms" => 300, "timeout_ms" => 500}
    start_copying!(ctx.tmp_dir, endpoint(port, "tcp", units, changes), token, clock, [])

    # Into the load survey: the histories and the snapshot are copied, the survey is not.
    assert_receive {:"$gen_cast", {:copy, %{port: ^port}, {:at, 1, :load_survey, :copying, n, _}}}
                   when n >= 3,
                   60_000

    shift!(shift, 3_600)
    copy_ended!(port, :window)
    await!("the buffer emptied", fn -> Buffer.backlog(Buffer).events == 0 end)

    held = held(m440, start)
    first = entries!("store.stored_entries", s440)
    assert map_size(first) < map_size(held)
    assert Map.take(held, Map.keys(first)) == first

    shift!(shift, 86_400)
    copy_ended!(port, :done)
    await!("the buffer emptied", fn -> Buffer.backlog(Buffer).events == 0 end)

    assert entries!("store.stored_entries", s440) == held

    # Only load-survey days are copied again: the one the window closed in, and the current day.
    rows = map_size(held)
    %{"inserted" => ^rows, "duplicate" => again, "conflicting" => 0} = upload_totals!(id)
    assert again in 1..(2 * 7 * 48)
  end
end
