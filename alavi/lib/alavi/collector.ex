defmodule Alavi.Collector do
  @moduledoc """
  The running collector: on Windows the clock's status, then the buffer, then
  the config keeper, then one poller per endpoint writing into the buffer,
  then the uplink, then the clock check, also writing into the buffer. Each of
  them casts what it did to `status` (an `Alavi.Status`, started elsewhere).
  """

  use Supervisor

  alias Alavi.{
    Buffer,
    Clock,
    Config,
    ConfigKeeper,
    Intake,
    Poller,
    Pollers,
    Profile,
    Settings,
    Status,
    Uplink
  }

  alias Alavi.Config.{Digest, Saved}
  alias Alavi.Poller.RawLog
  alias Alavi.Uplink.{HTTP, Response, Target}

  require Logger

  @typedoc """
  `uplink` is the uplink's options but `buffer`, `status`, `heartbeat_ms` and
  `intake` (the collector supplies them), or `:none` for no uplink (tests that
  inspect the buffer); the pollers nudge it after a read on demand only if it
  has a `name`. Its heartbeat is due after the shortest polling interval of
  any meter this collector polls without an answer from the server: one round
  of the meter polled most often; with no meter polled here, after the
  uplink's `idle_ms`. Its intake runs the jobs the server lists only if
  `pollers` is given, for it reaches them by that name. `clock_status` is the
  options of an `Alavi.Clock.Windows` to start first, or `:none`; the buffer's
  `clock_status` must read it if there is one. `clock_check` is the options
  of an `Alavi.Clock.Check` but `sink` and `status`, or `:none` for no
  checks (no NTP servers configured). `pollers` is the name to
  register the `Alavi.Pollers` under; without it they are unnamed (tests that
  start several collectors). The pollers keep their selector records
  (`Alavi.Selectors.Store`) in `selectors` under the buffer's `dir`, the
  collector's durable state. `config_keeper` is an `Alavi.ConfigKeeper`'s
  `digest` (of `config`), `profiles` and `name`, the collector supplying the
  rest and fetching through the uplink's target; `:none` for a collector that
  does not fetch its config, and always without an uplink.
  """
  @type option ::
          {:config, Config.t()}
          | {:buffer, [Buffer.option()]}
          | {:clock, Poller.clock()}
          | {:uplink, [Uplink.option()] | :none}
          | {:config_keeper, [ConfigKeeper.option()] | :none}
          | {:raw_log, RawLog.limits()}
          | {:clock_status, [Clock.Windows.option()] | :none}
          | {:clock_check, [Clock.Check.option()] | :none}
          | {:status, GenServer.server()}
          | {:pollers, atom()}
          | {:name, atom()}

  # contract: test/alavi/collector_test.exs "start_link/1"
  @spec start_link([option()]) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  # contract: test/alavi/collector_test.exs "load/2"
  @doc """
  The polling config is the one last served and saved under the buffer's
  `dir` (`Alavi.Config.Saved`) if there is one, else the local file.
  """
  @spec load(Settings.t(), {atom(), atom()}) :: {:ok, [option()]} | {:error, String.t()}
  def load(%Settings{} = settings, os) do
    {clock_status, watch} = clock(os, settings.clock.refresh_ms)

    with {:ok, uplink} <- uplink(settings),
         {:ok, profiles} <- Profile.load_dir(settings.profiles_dir),
         {:ok, config, digest} <- polling_config(settings, profiles) do
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
         config_keeper: [digest: digest, profiles: profiles, name: ConfigKeeper],
         raw_log: settings.raw_bytes_log,
         clock_status: watch,
         clock_check: check(settings.clock.ntp_servers),
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

    {keeper, keeper_name} =
      keeper(Keyword.fetch!(opts, :config_keeper), Keyword.fetch!(opts, :uplink),
        config: config,
        dir: Keyword.fetch!(buffer, :dir),
        status: status
      )

    {uplink, nudge} =
      case Keyword.fetch!(opts, :uplink) do
        :none ->
          {[], :none}

        uplink ->
          supplied = [
            buffer: Keyword.fetch!(buffer, :name),
            status: status,
            heartbeat_ms: heartbeat_ms(config, Keyword.fetch!(uplink, :idle_ms)),
            intake: intake(Keyword.get(opts, :pollers), config),
            config: keeper_name
          ]

          {[{Uplink, uplink ++ supplied}], Keyword.get(uplink, :name, :none)}
      end

    pollers = [
      config: config,
      sink: sink,
      clock: Keyword.fetch!(opts, :clock),
      raw_log: Keyword.fetch!(opts, :raw_log),
      status: status,
      uplink: nudge,
      selectors_dir: buffer |> Keyword.fetch!(:dir) |> Path.join("selectors")
    ]

    pollers = pollers ++ for {:pollers, name} <- opts, do: {:name, name}

    watch =
      case Keyword.fetch!(opts, :clock_status) do
        :none -> []
        watch -> [{Clock.Windows, Keyword.put(watch, :status, status)}]
      end

    check =
      case Keyword.fetch!(opts, :clock_check) do
        :none -> []
        check -> [{Clock.Check, check ++ [sink: sink, status: status]}]
      end

    Supervisor.init(
      watch ++ [{Buffer, buffer}] ++ keeper ++ [{Pollers, pollers}] ++ uplink ++ check,
      strategy: :rest_for_one
    )
  end

  defp keeper(:none, _uplink, _supplied), do: {[], :none}

  defp keeper(_keeper, :none, _supplied),
    do: raise(ArgumentError, "a config keeper fetches through the uplink, and there is none")

  defp keeper(keeper, uplink, supplied) do
    target = Keyword.fetch!(uplink, :target)
    timeout = Keyword.fetch!(uplink, :timeout_ms)
    fetch = fn -> target |> HTTP.get_config(timeout) |> Response.config() end
    opts = keeper ++ supplied ++ [fetch: fetch, applied: &applied/2]
    {[{ConfigKeeper, opts}], Keyword.fetch!(keeper, :name)}
  end

  # Where a served config reaches the running pollers. Until it does, it is
  # saved, and the collector starts from it.
  defp applied(%Config{}, digest),
    do:
      Logger.info(
        "alavi config: #{digest} is not applied to the running pollers; it is the config the collector starts from"
      )

  defp polling_config(settings, profiles) do
    case Saved.read(settings.buffer.dir) do
      {:ok, path, document} -> served(path, document, profiles, settings.polling_config)
      :none -> local(settings.polling_config, profiles)
      {:error, reason} -> {:error, "the config last served: #{reason}"}
    end
  end

  defp served(path, document, profiles, local) do
    case parsed(document, profiles) do
      {:ok, config, digest} ->
        {:ok, config, digest}

      {:error, reason} ->
        {:error,
         "#{path}, the config last served, does not parse with the profiles loaded: " <>
           "#{reason}; fix the profiles, or remove the file to start from #{local} " <>
           "until the server serves a config again"}
    end
  end

  defp local(path, profiles) do
    with {:ok, document} <- Config.read(path) do
      case parsed(document, profiles) do
        {:ok, config, digest} -> {:ok, config, digest}
        {:error, reason} -> {:error, "#{path}: #{reason}"}
      end
    end
  end

  defp parsed(document, profiles) do
    with {:ok, config} <- Config.parse(document, profiles),
         {:ok, digest} <- Digest.digest(document),
         do: {:ok, config, digest}
  end

  defp check([]), do: :none
  defp check(servers), do: Clock.Check.options(servers)

  defp heartbeat_ms(%Config{endpoints: endpoints}, idle_ms) do
    endpoints
    |> Enum.reject(& &1.polled_by_other_system)
    |> Enum.flat_map(& &1.meters)
    |> Enum.map(& &1.interval_ms)
    |> Enum.min(fn -> idle_ms end)
  end

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
