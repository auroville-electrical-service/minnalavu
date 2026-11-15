defmodule Alavi.Pollers.Applier do
  @moduledoc """
  Keeps an `Alavi.Pollers`' pollers to the config its keeper applies
  (`Alavi.ConfigKeeper.subscribe/1`), per endpoint by host and port: a poller
  whose endpoint is unchanged carries on untouched; an endpoint new to the
  config gets a poller; a poller whose endpoint changed or went is retired
  (`Alavi.Poller.retire/2`), so it stops at its next round boundary, and a
  changed one is then started again with its new settings. Each config
  applied also goes to the status (`Alavi.Status.polling/2`).

  What it compares is the endpoint each poller was started with, which the
  supervisor holds, so a restart of either loses nothing: started again, it
  retires afresh whatever polls what the config no longer says.
  """

  # contract: test/alavi/pollers/applier_test.exs "start_link/1"

  use GenServer

  require Logger

  alias Alavi.{Config, ConfigKeeper, Poller, Pollers, Status}
  alias Alavi.Config.Endpoint

  @typedoc "`shared` is every poller's options but its `endpoint`."
  @type option ::
          {:pollers, Supervisor.supervisor()}
          | {:keeper, GenServer.server()}
          | {:shared, [Poller.option()]}
          | {:status, GenServer.server()}

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    keeper = Keyword.fetch!(opts, :keeper)
    {config, _digest} = ConfigKeeper.subscribe(keeper)

    state = %{
      pollers: Keyword.fetch!(opts, :pollers),
      shared: Keyword.fetch!(opts, :shared),
      status: Keyword.fetch!(opts, :status),
      config: config,
      retiring: %{}
    }

    # The pollers' supervisor is still starting this process: it is asked nothing until it has.
    {:ok, state, {:continue, :apply}}
  end

  @impl true
  def handle_continue(:apply, state), do: {:noreply, applied(state)}

  @impl true
  def handle_info({:alavi_config, %Config{} = config, digest}, state) do
    Logger.info("alavi pollers: applying config #{digest}")
    {:noreply, applied(%{state | config: config})}
  end

  # A poller retired has stopped; one that crashed instead is started again
  # by the supervisor, and retired again here.
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {id, retiring} = Map.pop!(state.retiring, pid)
    _running = Supervisor.delete_child(state.pollers, id)
    {:noreply, settled(%{state | retiring: retiring})}
  end

  defp applied(state) do
    Status.polling(state.status, state.config)
    settled(state)
  end

  defp settled(state) do
    wanted = Map.new(state.config.endpoints, &{{&1.host, &1.port}, &1})
    state = state.pollers |> Pollers.pollers() |> Enum.reduce(state, &settle(&1, &2, wanted))

    present =
      for {{Poller, host, port}, _child} <- Pollers.pollers(state.pollers), do: {host, port}

    wanted |> Map.drop(present) |> Map.values() |> Enum.each(&start(&1, state))
    state
  end

  defp settle({{Poller, host, port} = id, child}, state, wanted) do
    case {Map.fetch(wanted, {host, port}), child, endpoint(state.pollers, id)} do
      {{:ok, same}, pid, same} when is_pid(pid) -> kept(state, pid, id)
      {{:ok, same}, :restarting, same} -> state
      {{:ok, %Endpoint{polled_by_other_system: true} = same}, :undefined, same} -> state
      {{:ok, _new}, pid, _old} when is_pid(pid) -> retire(state, pid, id, :replaced)
      {:error, pid, _old} when is_pid(pid) -> retire(state, pid, id, :removed)
      {_wanted, _not_running, _old} -> remove(state, id)
    end
  end

  # A poller that stopped before its supervisor saw it go is still listed:
  # watched, it is removed once the supervisor has.
  defp kept(state, pid, id), do: if(Process.alive?(pid), do: state, else: watched(state, pid, id))

  defp retire(state, pid, {Poller, host, port} = id, why) do
    Poller.retire(pid, why)

    if not Map.has_key?(state.retiring, pid),
      do:
        Logger.info("alavi pollers: #{host}:#{port} #{why}; it stops at its next round boundary")

    watched(state, pid, id)
  end

  defp watched(state, pid, id) do
    if Map.has_key?(state.retiring, pid) do
      state
    else
      Process.monitor(pid)
      %{state | retiring: Map.put(state.retiring, pid, id)}
    end
  end

  defp remove(state, id) do
    :ok = Supervisor.terminate_child(state.pollers, id)
    :ok = Supervisor.delete_child(state.pollers, id)
    state
  end

  defp start(%Endpoint{host: host, port: port} = endpoint, state) do
    {:ok, _child} =
      Supervisor.start_child(state.pollers, {Poller, [{:endpoint, endpoint} | state.shared]})

    Logger.info("alavi pollers: #{host}:#{port} started")
  end

  defp endpoint(pollers, id) do
    {:ok, %{start: {Poller, :start_link, [opts]}}} = :supervisor.get_childspec(pollers, id)
    Keyword.fetch!(opts, :endpoint)
  end
end
