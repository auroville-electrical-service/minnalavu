defmodule Alavi.EndToEndTest do
  @moduledoc """
  Simulator -> pollers -> buffer -> uplink -> PostgREST -> database, with the
  rows checked in the database. Needs the dev environment's central store,
  migrated: see CLAUDE.md. Excluded from `mix test` and `mix check`; run with
  `bin/dev alavi mix test --only e2e`.
  """

  use ExUnit.Case, async: false

  import Alavi.PollerCase

  alias Alavi.{Buffer, Clock, Collector, FakeNtp, Uplink}
  alias Alavi.Config.{Digest, Saved}
  alias Alavi.Uplink.Target

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
        [env!("MINNALAVU_DB_URL"), "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1"] ++
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
       ) do
    {:ok, target} =
      Target.parse(env!("MINNALAVU_API_URL"), token, allow_http: true, cacerts: [])

    buffer = [
      dir: dir,
      max_bytes: 1_000_000,
      max_batch_events: 1_000,
      clock_status: &Clock.unsynced/0,
      name: Buffer
    ]

    uplink = [
      target: target,
      clock: &DateTime.utc_now/0,
      idle_ms: 50,
      backoff_ms: %{min: 50, max: 500},
      timeout_ms: 5_000
    ]

    opts = [
      config: config!(endpoints),
      buffer: buffer,
      clock: clock,
      uplink: uplink,
      config_keeper: keeper,
      raw_log: raw_log(),
      clock_status: :none,
      clock_check: :none,
      status: no_status()
    ]

    start_supervised!({Collector, opts ++ named})
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
    # Random, not unique_integer: the dev database keeps earlier runs' collectors.
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
    # Random, not unique_integer: the dev database keeps earlier runs' collectors.
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
      reconnect_backoff_min_ms => 10, reconnect_backoff_max_ms => 40, interval_ms => 1500))
    """)

    sql!("""
    SELECT to_json(admin.register_target(endpoint_id => '#{id}_ep', unit_id => 3,
      valid_from => '2026-01-01Z', profile => 'elite_500', interval_ms => NULL))
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
    {:ok, target} =
      Target.parse(env!("MINNALAVU_API_URL"), token, allow_http: true, cacerts: [])

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
    # The dev database keeps earlier runs' readings, which a fixed clock would repeat.
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
      reconnect_backoff_min_ms => 10, reconnect_backoff_max_ms => 40, interval_ms => 300))
    """)

    sql!("""
    SELECT to_json(admin.register_target(endpoint_id => '#{id}_ep', unit_id => 1,
      valid_from => '2026-01-01Z', profile => 'elite_440', interval_ms => NULL))
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
      valid_from => now(), profile => 'elite_440', interval_ms => 600))
    """)

    second = served.()
    refute second == first

    await!("the changed config fetched, saved and reported", fn ->
      match?(%{"digest" => ^second, "refused" => nil}, reported.()) and saved.() == second
    end)

    # A profile this collector has not loaded: the whole config is refused.
    sql!("""
    SELECT to_json(admin.change_target(endpoint_id => '#{id}_ep', unit_id => 1,
      valid_from => now(), profile => 'no_such_profile', interval_ms => 600))
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
      reconnect_backoff_min_ms => 10, reconnect_backoff_max_ms => 40, interval_ms => 300))
    """)
  end

  defp register_target!(id, name, unit, profile, valid_from \\ "'2026-01-01Z'") do
    sql!("""
    SELECT to_json(admin.register_target(endpoint_id => '#{id}_#{name}', unit_id => #{unit},
      valid_from => #{valid_from}, profile => '#{profile}', interval_ms => NULL))
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
end
