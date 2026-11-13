defmodule Alavi.ConfigTest do
  use ExUnit.Case, async: true

  import Alavi.PollerCase

  alias Alavi.Config
  alias Alavi.Config.{Endpoint, Meter}

  defp doc(endpoints), do: %{"schema_version" => 1, "endpoints" => endpoints}

  defp valid,
    do:
      doc([
        endpoint(502, "tcp", [meter(1, "elite_440"), meter(3, "elite_500", %{"interval_ms" => 5})]),
        endpoint(503, "rtu_over_tcp", [meter(1, "elite_440", %{"serial" => "B-1"})])
      ])

  describe "parse/2" do
    test "parses endpoints and meters; a meter without an interval takes its endpoint's" do
      assert {:ok, %Config{endpoints: [tcp, rtu]}} = Config.parse(valid(), profiles())

      assert %Endpoint{framing: :tcp, max_timeouts: 3, port: 502, retries: 2} = tcp
      assert %Endpoint{framing: :rtu_over_tcp, max_timeouts: nil} = rtu
      assert tcp.reconnect_backoff_ms == %{min: 10, max: 40}

      assert [%Meter{unit_id: 1, interval_ms: 60_000}, %Meter{unit_id: 3, interval_ms: 5}] =
               tcp.meters

      assert hd(tcp.meters).profile.name == "elite_440"
    end

    # {name, path into the valid document, new value or :delete, expected error fragment}.
    @broken [
      {"schema version 2", ["schema_version"], 2, "schema_version 2"},
      {"no endpoints", ["endpoints"], [], "endpoints must be a non-empty list"},
      {"an unknown field", ["endpoints", 0, "intervall"], 5,
       "endpoints[0]: unknown field(s) intervall"},
      {"a missing field (no defaults)", ["endpoints", 0, "retries"], :delete,
       "endpoints[0]: retries must be an integer"},
      {"an unknown framing", ["endpoints", 0, "framing"], "udp", "framing must be one of"},
      {"tcp without max_timeouts", ["endpoints", 0, "max_timeouts"], :delete,
       "max_timeouts must be"},
      {"rtu with max_timeouts", ["endpoints", 1, "max_timeouts"], 3,
       "endpoints[1]: max_timeouts applies only to framing tcp"},
      {"a string flag", ["endpoints", 0, "polled_by_other_system"], "no",
       "polled_by_other_system must be true or false"},
      {"backoff max below min", ["endpoints", 0, "reconnect_backoff_ms", "max"], 5,
       "reconnect_backoff_ms: max must be an integer in 10.."},
      {"unit id 248", ["endpoints", 0, "meters", 0, "unit_id"], 248,
       "endpoints[0]: meters[0]: unit_id must be an integer in 1..247"},
      {"an unknown profile", ["endpoints", 0, "meters", 0, "profile"], "elite_999",
       ~s(profile "elite_999" is not among the loaded profiles)},
      {"interval 0", ["endpoints", 0, "meters", 1, "interval_ms"], 0,
       "meters[1]: interval_ms must be an integer in 1.."},
      {"a repeated unit id", ["endpoints", 0, "meters", 1, "unit_id"], 1,
       "endpoints[0]: unit_id 1 appears more than once"},
      {"a repeated endpoint", ["endpoints", 1, "port"], 502,
       "endpoint 127.0.0.1:502 appears more than once"},
      {"a repeated serial", ["endpoints", 1, "meters", 0, "serial"], "SIM-elite_440-1",
       ~s(serial "SIM-elite_440-1" appears more than once)}
    ]

    for {name, path, value, message} <- @broken do
      test "rejects #{name}" do
        json = change(valid(), unquote(path), unquote(value))
        assert {:error, reason} = Config.parse(json, profiles())
        assert reason =~ unquote(message)
      end
    end
  end

  describe "load/2" do
    test "loads a config file" do
      path =
        Path.join(System.tmp_dir!(), "alavi-config-#{System.unique_integer([:positive])}.json")

      File.write!(path, JSON.encode!(valid()))
      on_exit(fn -> File.rm(path) end)

      assert {:ok, %Config{endpoints: [_, _]}} = Config.load(path, profiles())

      assert {:error, "#{path}.missing: no such file or directory"} ==
               Config.load(path <> ".missing", profiles())
    end
  end

  defp change(json, path, :delete), do: json |> pop_in(access(path)) |> elem(1)
  defp change(json, path, value), do: put_in(json, access(path), value)

  defp access(path),
    do:
      Enum.map(path, fn
        i when is_integer(i) -> Access.at(i)
        key -> key
      end)
end
