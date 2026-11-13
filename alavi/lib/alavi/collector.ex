defmodule Alavi.Collector do
  @moduledoc """
  The running collector: on Windows the clock's status, then the buffer, then
  one poller per endpoint writing into it, then the uplink.
  """

  use Supervisor

  alias Alavi.{Buffer, Clock, Config, Poller, Pollers, Profile, Settings, Uplink}
  alias Alavi.Poller.RawLog
  alias Alavi.Uplink.Target

  @typedoc """
  `uplink` is the uplink's options but `buffer` (the collector supplies it), or
  `:none` for no uplink (tests that inspect the buffer). `clock_status` is the
  options of an `Alavi.Clock.Windows` to start first, or `:none`; the buffer's
  `clock_status` must read it if there is one.
  """
  @type option ::
          {:config, Config.t()}
          | {:buffer, [Buffer.option()]}
          | {:clock, Poller.clock()}
          | {:uplink, [Uplink.option()] | :none}
          | {:raw_log, RawLog.limits()}
          | {:clock_status, [Clock.Windows.option()] | :none}
          | {:name, atom()}

  # contract: test/alavi/collector_test.exs "start_link/1"
  @spec start_link([option()]) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  # contract: test/alavi/collector_test.exs "load/2"
  @spec load(Settings.t(), {atom(), atom()}) :: {:ok, [option()]} | {:error, String.t()}
  def load(%Settings{} = settings, os) do
    {clock_status, watch} = clock(os, settings.clock.refresh_ms)

    with {:ok, uplink} <- uplink(settings),
         {:ok, profiles} <- Profile.load_dir(settings.profiles_dir),
         {:ok, config} <- Config.load(settings.polling_config, profiles) do
      buffer = [
        dir: settings.buffer.dir,
        max_bytes: settings.buffer.max_bytes,
        max_batch_events: settings.buffer.max_batch_events,
        clock_status: clock_status,
        name: Buffer
      ]

      {:ok,
       [
         config: config,
         buffer: buffer,
         clock: &DateTime.utc_now/0,
         uplink: uplink,
         raw_log: settings.raw_bytes_log,
         clock_status: watch
       ]}
    end
  end

  @impl true
  def init(opts) do
    buffer = Keyword.fetch!(opts, :buffer)
    sink = {Buffer, Keyword.fetch!(buffer, :name)}

    pollers = [
      config: Keyword.fetch!(opts, :config),
      sink: sink,
      clock: Keyword.fetch!(opts, :clock),
      raw_log: Keyword.fetch!(opts, :raw_log)
    ]

    uplink =
      case Keyword.fetch!(opts, :uplink) do
        :none -> []
        uplink -> [{Uplink, Keyword.put(uplink, :buffer, Keyword.fetch!(buffer, :name))}]
      end

    watch =
      case Keyword.fetch!(opts, :clock_status) do
        :none -> []
        watch -> [{Clock.Windows, watch}]
      end

    Supervisor.init(watch ++ [{Buffer, buffer}, {Pollers, pollers}] ++ uplink,
      strategy: :rest_for_one
    )
  end

  defp clock({:win32, _}, refresh_ms) do
    watch = [
      query: &Clock.Windows.w32tm/0,
      clock: &DateTime.utc_now/0,
      refresh_ms: refresh_ms,
      name: Clock.Windows
    ]

    {fn -> Clock.Windows.status(Clock.Windows) end, watch}
  end

  defp clock(_os, _refresh_ms), do: {&Clock.unsynced/0, :none}

  defp uplink(%Settings{server: server, uplink: uplink}) do
    with {:ok, cacerts} <- os_cacerts(),
         {:ok, target} <-
           Target.parse(server.url, server.token, allow_http: false, cacerts: cacerts) do
      {:ok,
       [
         target: target,
         clock: &DateTime.utc_now/0,
         idle_ms: uplink.idle_ms,
         timeout_ms: uplink.timeout_ms,
         backoff_ms: uplink.backoff_ms
       ]}
    end
  end

  defp os_cacerts do
    case :public_key.cacerts_load() do
      :ok -> {:ok, :public_key.cacerts_get()}
      {:error, reason} -> {:error, "cannot load the OS's CA certificates: #{inspect(reason)}"}
    end
  end
end
