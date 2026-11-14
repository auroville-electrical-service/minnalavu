defmodule Alavi.Collector do
  @moduledoc """
  The running collector: on Windows the clock's status, then the buffer, then
  one poller per endpoint writing into it, then the uplink. Each of them casts
  what it did to `status` (an `Alavi.Status`, started elsewhere).
  """

  use Supervisor

  alias Alavi.{Buffer, Clock, Config, Intake, Poller, Pollers, Profile, Settings, Status, Uplink}
  alias Alavi.Poller.RawLog
  alias Alavi.Uplink.Target

  @typedoc """
  `uplink` is the uplink's options but `buffer`, `status`, `heartbeat_ms` and
  `intake` (the collector supplies them), or `:none` for no uplink (tests that
  inspect the buffer); the pollers nudge it after a read on demand only if it
  has a `name`. Its heartbeat is due after the shortest polling interval of
  any meter in the config without an answer from the server: one round of the
  meter polled most often. Its intake runs the jobs the server lists only if
  `pollers` is given, for it reaches them by that name. `clock_status` is the
  options of an `Alavi.Clock.Windows` to start first, or `:none`; the buffer's
  `clock_status` must read it if there is one. `pollers` is the name to
  register the `Alavi.Pollers` under; without it they are unnamed (tests that
  start several collectors).
  """
  @type option ::
          {:config, Config.t()}
          | {:buffer, [Buffer.option()]}
          | {:clock, Poller.clock()}
          | {:uplink, [Uplink.option()] | :none}
          | {:raw_log, RawLog.limits()}
          | {:clock_status, [Clock.Windows.option()] | :none}
          | {:status, GenServer.server()}
          | {:pollers, atom()}
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
         clock_status: watch,
         status: Status,
         pollers: Pollers
       ]}
    end
  end

  @impl true
  def init(opts) do
    buffer = Keyword.fetch!(opts, :buffer)
    sink = {Buffer, Keyword.fetch!(buffer, :name)}
    status = Keyword.fetch!(opts, :status)
    config = Keyword.fetch!(opts, :config)

    {uplink, nudge} =
      case Keyword.fetch!(opts, :uplink) do
        :none ->
          {[], :none}

        uplink ->
          supplied = [
            buffer: Keyword.fetch!(buffer, :name),
            status: status,
            heartbeat_ms: heartbeat_ms(config),
            intake: intake(Keyword.get(opts, :pollers), config)
          ]

          {[{Uplink, uplink ++ supplied}], Keyword.get(uplink, :name, :none)}
      end

    pollers = [
      config: config,
      sink: sink,
      clock: Keyword.fetch!(opts, :clock),
      raw_log: Keyword.fetch!(opts, :raw_log),
      status: status,
      uplink: nudge
    ]

    pollers = pollers ++ for {:pollers, name} <- opts, do: {:name, name}

    watch =
      case Keyword.fetch!(opts, :clock_status) do
        :none -> []
        watch -> [{Clock.Windows, Keyword.put(watch, :status, status)}]
      end

    Supervisor.init(watch ++ [{Buffer, buffer}, {Pollers, pollers}] ++ uplink,
      strategy: :rest_for_one
    )
  end

  defp heartbeat_ms(%Config{endpoints: endpoints}),
    do: endpoints |> Enum.flat_map(& &1.meters) |> Enum.map(& &1.interval_ms) |> Enum.min()

  defp intake(nil, _config), do: :none
  defp intake(pollers, config), do: Intake.new(pollers, config)

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
         backoff_ms: uplink.backoff_ms,
         name: Uplink
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
