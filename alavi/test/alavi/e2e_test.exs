defmodule Alavi.EndToEndTest do
  @moduledoc """
  Simulator -> pollers -> buffer -> uplink -> PostgREST -> database, with the
  rows checked in the database. Needs the dev environment's central store,
  migrated: see CLAUDE.md. Excluded from `mix test` and `mix check`; run with
  `bin/dev alavi mix test --only e2e`.
  """

  use ExUnit.Case, async: false

  import Alavi.PollerCase

  alias Alavi.{Buffer, Clock, Collector, Uplink}
  alias Alavi.Uplink.Target

  @moduletag :e2e
  @moduletag :tmp_dir
  @moduletag :capture_log
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
    {token, 0} = System.cmd("bash", [@token_script, id, "1"])
    String.trim(token)
  end

  defp start_collector!(dir, endpoints, token, named \\ []) do
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
      clock: &DateTime.utc_now/0,
      uplink: uplink,
      raw_log: raw_log(),
      clock_status: :none,
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

    # The registry knows the meter by the serial it reports; the polling config expects none.
    sql!("""
    SELECT to_json(admin.register_endpoint(
      endpoint_id => '#{id}_ep', valid_from => '2026-01-01Z', collector_id => '#{id}',
      host => '127.0.0.1', port => #{port}, framing => 'tcp', polled_by_other_system => false,
      timeout_ms => 100, max_timeouts => 3, retries => 2, busy_backoff_ms => 10,
      reconnect_backoff_min_ms => 10, reconnect_backoff_max_ms => 40, interval_ms => 1500))
    """)

    sql!("""
    SELECT to_json(admin.register_meter(serial => '#{serial}', valid_from => '2026-01-01Z',
      endpoint_id => '#{id}_ep', unit_id => 3, profile => 'elite_500', interval_ms => NULL))
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

  test "a heartbeat is stored as an upload of nothing", ctx do
    {id, token} = new_collector!()

    {:ok, target} =
      Target.parse(env!("MINNALAVU_API_URL"), token, allow_http: true, cacerts: [])

    buffer = :"buffer_#{id}"

    start_supervised!(
      {Buffer,
       dir: ctx.tmp_dir,
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
       backoff_ms: %{min: 50, max: 500},
       timeout_ms: 5_000,
       status: no_status()}
    )

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
end
