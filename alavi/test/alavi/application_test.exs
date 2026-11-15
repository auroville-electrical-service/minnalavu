defmodule Alavi.ApplicationTest do
  # Not async: a release's children have fixed names (Alavi.Buffer, Alavi.Status).
  use ExUnit.Case, async: false

  import Alavi.PollerCase
  import ExUnit.CaptureLog

  alias Alavi.{Settings, Status}

  @moduletag :tmp_dir

  defp settings!(dir, sim_port, status_port) do
    polling = Path.join(dir, "polling.json")
    endpoints = [endpoint(sim_port, "tcp", [meter(1, "elite_440")])]
    File.write!(polling, JSON.encode!(%{"schema_version" => 1, "endpoints" => endpoints}))
    log = dir |> Path.join("log") |> tap(&File.mkdir_p!/1)

    json = %{
      "schema_version" => 3,
      "polling_config" => polling,
      "profiles_dir" => Simulator.Profile.dir(),
      "buffer" => %{
        "dir" => Path.join(dir, "buffer"),
        "max_bytes" => 2_000_000_000,
        "max_batch_events" => 1000
      },
      "server" => %{"url" => "https://store.example/", "token" => "header.payload.signature"},
      "uplink" => %{
        "idle_ms" => 60_000,
        "timeout_ms" => 1_000,
        "backoff_ms" => %{"min" => 60_000, "max" => 60_000}
      },
      "log" => %{"dir" => log, "max_file_bytes" => 1_000_000, "max_files" => 2},
      "raw_bytes_log" => %{"max_frame_bytes" => 64, "max_lines" => 10, "window_ms" => 60_000},
      "clock" => %{"refresh_ms" => 300_000, "ntp_servers" => []},
      "status" => %{"port" => status_port}
    }

    {:ok, settings} = Settings.parse(json)
    settings
  end

  describe "children/1" do
    test "a status port already in use is logged, and the collector starts and polls",
         %{tmp_dir: dir} do
      {_sim, sim_port} = start_sim!(:tcp)
      {:ok, taken} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, status_port} = :inet.port(taken)
      {:ok, children} = Alavi.Application.children(settings!(dir, sim_port, status_port))

      log =
        capture_log(fn ->
          start_supervised!(%{
            id: :release,
            start: {Supervisor, :start_link, [children, [strategy: :one_for_one]]},
            type: :supervisor
          })

          :ok =
            eventually!(fn ->
              [meter] = hd(Status.read(Status).endpoints).meters
              meter.serial == "SIM-1"
            end)

          assert Alavi.Buffer.backlog(Alavi.Buffer).events > 0
          :ok = eventually!(fn -> File.exists?(Path.join([dir, "log", "status.json"])) end)
        end)

      assert log =~ "the status page cannot listen on 127.0.0.1:#{status_port}"
    end
  end
end
