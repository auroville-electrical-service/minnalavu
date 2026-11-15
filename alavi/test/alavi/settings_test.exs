defmodule Alavi.SettingsTest do
  use ExUnit.Case, async: true

  alias Alavi.Settings

  @moduletag :tmp_dir
  @example Path.expand("../../rel/overlays/settings.example.json", __DIR__)

  defp example, do: @example |> File.read!() |> JSON.decode!()

  # Every leaf key of a decoded document, as a path of keys.
  defp leaves(map, prefix \\ []) do
    Enum.flat_map(map, fn
      {key, value} when is_map(value) -> leaves(value, prefix ++ [key])
      {key, _value} -> [prefix ++ [key]]
    end)
  end

  describe "load/1" do
    test "the shipped example parses, Windows paths as written" do
      assert {:ok, %Settings{} = settings} = Settings.load(@example)
      assert settings.polling_config == "C:\\alavi\\polling.json"
      assert settings.buffer.dir == "C:\\alavi\\buffer"
      assert settings.uplink.backoff_ms == %{min: 1000, max: 300_000}
    end

    test "a file that is missing or not JSON is named", %{tmp_dir: dir} do
      missing = Path.join(dir, "settings.json")
      assert {:error, "settings file " <> rest} = Settings.load(missing)
      assert rest =~ "#{missing}: no such file"

      File.write!(missing, "{\"schema_version\": 1,")
      assert {:error, message} = Settings.load(missing)
      assert message =~ "#{missing}: invalid JSON"
    end
  end

  describe "log_file/1" do
    test "the log file is alavi.log in log.dir, rotated as the settings say" do
      {:ok, settings} = Settings.parse(example())

      assert %{file: file, max_no_bytes: 10_000_000, max_no_files: 10} =
               Settings.log_file(settings)

      assert file == ~c"C:\\alavi\\log/alavi.log"
    end
  end

  describe "parse/1" do
    test "forward slashes and drive letters are taken as written" do
      json = put_in(example(), ["buffer", "dir"], "D:/alavi data/buffer")
      assert {:ok, %Settings{buffer: %{dir: "D:/alavi data/buffer"}}} = Settings.parse(json)
    end

    test "every key is required, and the error names it" do
      for [_ | _] = path <- leaves(example()), path != ["schema_version"] do
        {_, json} = pop_in(example(), path)
        key = Enum.join(path, ".")
        assert {:error, message} = Settings.parse(json)
        assert message =~ ~r/^#{Regex.escape(key)} must be /, "#{key}: #{message}"
      end
    end

    test "a missing group names its first key" do
      assert {:error, "buffer.dir must be a non-empty string"} =
               Settings.parse(Map.delete(example(), "buffer"))
    end

    test "unknown keys are rejected by name, at any depth" do
      assert {:error, "unknown field(s) log_level"} =
               Settings.parse(Map.put(example(), "log_level", "debug"))

      assert {:error, "unknown field(s) uplink.backoff_ms.factor"} =
               Settings.parse(put_in(example(), ["uplink", "backoff_ms", "factor"], 2))
    end

    test "numbers must be positive JSON integers" do
      for bad <- [0, -5, 1.5, "1000", nil] do
        json = put_in(example(), ["buffer", "max_batch_events"], bad)

        assert {:error, "buffer.max_batch_events must be a positive integer"} =
                 Settings.parse(json)
      end
    end

    test "the uplink's backoff must not shrink" do
      json = put_in(example(), ["uplink", "backoff_ms", "min"], 300_001)

      assert {:error, "uplink.backoff_ms.min must not exceed uplink.backoff_ms.max"} =
               Settings.parse(json)
    end

    test "a document that is not an object, or of another version, is rejected" do
      assert {:error, "expected a JSON object with schema_version 3"} = Settings.parse([])

      assert {:error, "unsupported settings schema_version 4"} =
               Settings.parse(%{example() | "schema_version" => 4})
    end

    test "a file of an earlier version is refused with what each later version added" do
      {_, v1} = pop_in(%{example() | "schema_version" => 1}, ["status"])
      assert {:error, message} = Settings.parse(v1)
      assert message =~ "schema_version 1"
      assert message =~ ~s("status": {"port")
      assert message =~ ~s("ntp_servers")
      assert message =~ "set schema_version to 3"

      {_, v2} = pop_in(%{example() | "schema_version" => 2}, ["clock", "ntp_servers"])
      assert {:error, message} = Settings.parse(v2)
      assert message =~ "schema_version 2"
      refute message =~ ~s("status")
      assert message =~ ~s("ntp_servers")
    end

    test "the NTP servers are a list of names or addresses, which may be empty" do
      assert {:ok, %Settings{clock: %{ntp_servers: ["pool.ntp.org"]}}} = Settings.parse(example())

      for servers <- [[], ["192.0.2.1", "ntp.example", "2001:db8::1"]] do
        json = put_in(example(), ["clock", "ntp_servers"], servers)
        assert {:ok, %Settings{clock: %{ntp_servers: ^servers}}} = Settings.parse(json)
      end

      for bad <- ["pool.ntp.org", [""], ["two words"], [1], [String.duplicate("a", 254)], nil] do
        json = put_in(example(), ["clock", "ntp_servers"], bad)
        assert {:error, "clock.ntp_servers must be a list" <> _} = Settings.parse(json)
      end
    end

    test "the status port is a TCP port" do
      for bad <- [0, 65_536, "8502"] do
        assert {:error, "status.port must be an integer in 1..65535"} =
                 Settings.parse(put_in(example(), ["status", "port"], bad))
      end

      assert {:ok, %Settings{status: %{port: 8502}}} = Settings.parse(example())
    end
  end

  describe "shown/1" do
    test "every setting by its dotted key, except the token" do
      {:ok, settings} = Settings.parse(example())
      shown = Settings.shown(settings)

      assert {"status.port", 8502} in shown
      assert {"clock.ntp_servers", "pool.ntp.org"} in shown
      assert {"buffer.dir", "C:\\alavi\\buffer"} in shown
      refute Enum.any?(shown, fn {key, _value} -> key == "server.token" end)
      refute Enum.any?(shown, fn {_key, value} -> value == settings.server.token end)
    end

    # Fails when a setting is added: name it in `shown/1`'s list, or here if it
    # must never reach the status page.
    test "every setting is either shown or named as never shown" do
      {:ok, settings} = Settings.parse(example())
      shown = settings |> Settings.shown() |> Enum.map(&elem(&1, 0))
      never_shown = ["server.token"]
      all = example() |> leaves() |> Enum.map(&Enum.join(&1, "."))

      assert Enum.sort(shown ++ never_shown) == Enum.sort(all)
    end
  end
end
