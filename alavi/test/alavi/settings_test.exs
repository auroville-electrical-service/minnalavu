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
      assert {:error, "expected a JSON object with schema_version 1"} = Settings.parse([])

      assert {:error, "unsupported settings schema_version 2"} =
               Settings.parse(%{example() | "schema_version" => 2})
    end
  end
end
