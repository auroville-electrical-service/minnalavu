defmodule Alavi.Settings do
  @moduledoc """
  A release's settings: one JSON file, `settings.json` in the release root,
  read once at startup by `config/runtime.exs`.

  ## Document, schema version 1

      {
        "schema_version": 1,
        "polling_config": "C:\\\\alavi\\\\polling.json",
        "profiles_dir": "C:\\\\alavi\\\\profiles",
        "buffer": {"dir": "C:\\\\alavi\\\\buffer", "max_bytes": 2000000000, "max_batch_events": 1000},
        "server": {"url": "https://store.example.org/", "token": "header.payload.signature"},
        "uplink": {"idle_ms": 60000, "timeout_ms": 30000, "backoff_ms": {"min": 1000, "max": 300000}},
        "log": {"dir": "C:\\\\alavi\\\\log", "max_file_bytes": 10000000, "max_files": 10},
        "raw_bytes_log": {"max_frame_bytes": 64, "max_lines": 10, "window_ms": 60000},
        "clock": {"refresh_ms": 300000}
      }

  - `server.url`: the server's base URL (PostgREST's root), `https://` only;
    `server.token`: the collector's token, which is also its identity;
  - `uplink.idle_ms`: how long to wait before looking at an empty buffer
    again; `uplink.timeout_ms`: how long a POST may take to connect, and to be
    answered; `uplink.backoff_ms`: the wait after a failed send, doubling from
    `min` to `max`;
  - `log.max_file_bytes`: the size at which the log is rotated, keeping
    `log.max_files` rotated files besides the current one;
  - `raw_bytes_log`: per-endpoint caps on logging the raw bytes of unexpected
    replies;
  - `clock.refresh_ms`: on Windows, how often the Windows Time service is
    asked for the clock's status. Required everywhere.

  Paths are taken as written; in JSON a backslash is written `\\\\`, or use
  `/`. Whether the files exist is checked by `Alavi.Collector.load/2`, not here.
  """

  alias Alavi.Config.Fields

  @enforce_keys [
    :polling_config,
    :profiles_dir,
    :buffer,
    :server,
    :uplink,
    :log,
    :raw_bytes_log,
    :clock
  ]
  defstruct @enforce_keys

  @type buffer :: %{dir: Path.t(), max_bytes: pos_integer(), max_batch_events: pos_integer()}
  @type server :: %{url: String.t(), token: String.t()}
  @type uplink :: %{
          idle_ms: pos_integer(),
          timeout_ms: pos_integer(),
          backoff_ms: %{min: pos_integer(), max: pos_integer()}
        }
  @type log :: %{dir: Path.t(), max_file_bytes: pos_integer(), max_files: pos_integer()}

  @type t :: %__MODULE__{
          polling_config: Path.t(),
          profiles_dir: Path.t(),
          buffer: buffer(),
          server: server(),
          uplink: uplink(),
          log: log(),
          raw_bytes_log: Alavi.Poller.RawLog.limits(),
          clock: %{refresh_ms: pos_integer()}
        }

  @keys ~w(schema_version polling_config profiles_dir
           buffer.dir buffer.max_bytes buffer.max_batch_events
           server.url server.token
           uplink.idle_ms uplink.timeout_ms uplink.backoff_ms.min uplink.backoff_ms.max
           log.dir log.max_file_bytes log.max_files
           raw_bytes_log.max_frame_bytes raw_bytes_log.max_lines raw_bytes_log.window_ms
           clock.refresh_ms)

  # contract: test/alavi/settings_test.exs "load/1"
  @spec load(Path.t()) :: {:ok, t()} | {:error, String.t()}
  def load(path) do
    with {:ok, text} <- read(path),
         {:ok, json} <- decode(text),
         {:ok, settings} <- parse(json) do
      {:ok, settings}
    else
      {:error, reason} -> {:error, "settings file #{path}: #{reason}"}
    end
  end

  # contract: test/alavi/settings_test.exs "parse/1"
  @spec parse(term()) :: {:ok, t()} | {:error, String.t()}
  def parse(%{"schema_version" => 1} = json) do
    flat = flatten(json)

    with {:ok, fields} <- parse_all(flat),
         :ok <- Fields.only(flat, @keys) do
      {:ok, struct!(__MODULE__, fields)}
    end
  end

  def parse(%{"schema_version" => version}),
    do: {:error, "unsupported settings schema_version #{inspect(version)}"}

  def parse(_json), do: {:error, "expected a JSON object with schema_version 1"}

  # contract: test/alavi/settings_test.exs "log_file/1"
  @doc "The options of the `:logger_std_h` handler that writes the log file."
  @spec log_file(t()) :: map()
  def log_file(%__MODULE__{log: log}) do
    %{
      file: log.dir |> Path.join("alavi.log") |> String.to_charlist(),
      max_no_bytes: log.max_file_bytes,
      max_no_files: log.max_files
    }
  end

  defp parsers do
    [
      polling_config: &Fields.string(&1, "polling_config"),
      profiles_dir: &Fields.string(&1, "profiles_dir"),
      buffer: &buffer/1,
      server: &server/1,
      uplink: &uplink/1,
      log: &log/1,
      raw_bytes_log: &raw_bytes_log/1,
      clock: &clock/1
    ]
  end

  defp parse_all(flat) do
    Enum.reduce_while(parsers(), {:ok, %{}}, fn {key, parse}, {:ok, acc} ->
      case parse.(flat) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp buffer(flat) do
    with {:ok, dir} <- Fields.string(flat, "buffer.dir"),
         {:ok, max_bytes} <- Fields.positive(flat, "buffer.max_bytes"),
         {:ok, max_events} <- Fields.positive(flat, "buffer.max_batch_events") do
      {:ok, %{dir: dir, max_bytes: max_bytes, max_batch_events: max_events}}
    end
  end

  defp server(flat) do
    with {:ok, url} <- Fields.string(flat, "server.url"),
         {:ok, token} <- Fields.string(flat, "server.token") do
      {:ok, %{url: url, token: token}}
    end
  end

  defp uplink(flat) do
    with {:ok, idle} <- Fields.positive(flat, "uplink.idle_ms"),
         {:ok, timeout} <- Fields.positive(flat, "uplink.timeout_ms"),
         {:ok, min} <- Fields.positive(flat, "uplink.backoff_ms.min"),
         {:ok, max} <- Fields.positive(flat, "uplink.backoff_ms.max"),
         :ok <- ordered(min, max, "uplink.backoff_ms") do
      {:ok, %{idle_ms: idle, timeout_ms: timeout, backoff_ms: %{min: min, max: max}}}
    end
  end

  defp log(flat) do
    with {:ok, dir} <- Fields.string(flat, "log.dir"),
         {:ok, max_bytes} <- Fields.positive(flat, "log.max_file_bytes"),
         {:ok, max_files} <- Fields.positive(flat, "log.max_files") do
      {:ok, %{dir: dir, max_file_bytes: max_bytes, max_files: max_files}}
    end
  end

  defp raw_bytes_log(flat) do
    with {:ok, bytes} <- Fields.positive(flat, "raw_bytes_log.max_frame_bytes"),
         {:ok, lines} <- Fields.positive(flat, "raw_bytes_log.max_lines"),
         {:ok, window} <- Fields.positive(flat, "raw_bytes_log.window_ms") do
      {:ok, %{max_frame_bytes: bytes, max_lines: lines, window_ms: window}}
    end
  end

  defp clock(flat) do
    with {:ok, ms} <- Fields.positive(flat, "clock.refresh_ms"), do: {:ok, %{refresh_ms: ms}}
  end

  defp ordered(min, max, _key) when min <= max, do: :ok
  defp ordered(_min, _max, key), do: {:error, "#{key}.min must not exceed #{key}.max"}

  defp flatten(map, prefix \\ "") do
    Enum.reduce(map, %{}, fn
      {key, value}, acc when is_map(value) -> Map.merge(acc, flatten(value, "#{prefix}#{key}."))
      {key, value}, acc -> Map.put(acc, prefix <> key, value)
    end)
  end

  defp read(path) do
    case File.read(path) do
      {:ok, text} -> {:ok, text}
      {:error, reason} -> {:error, :file.format_error(reason) |> to_string()}
    end
  end

  defp decode(text) do
    case JSON.decode(text) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, "invalid JSON (#{inspect(reason)})"}
    end
  end
end
