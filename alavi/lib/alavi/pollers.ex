defmodule Alavi.Pollers do
  @moduledoc """
  One `Alavi.Poller` per endpoint of the config. Given a config, they poll it
  until they stop; given `{:keeper, keeper}`, they start from the config the
  `Alavi.ConfigKeeper` applies now and follow each it applies after
  (`Alavi.Pollers.Applier`), whichever of them restarts.
  """

  use Supervisor

  alias Alavi.{Config, ConfigKeeper, Poller, Sink}
  alias Alavi.Poller.RawLog
  alias Alavi.Pollers.Applier

  @type option ::
          {:config, Config.t() | {:keeper, GenServer.server()}}
          | {:sink, Sink.t()}
          | {:clock, Poller.clock()}
          | {:raw_log, RawLog.limits()}
          | {:status, GenServer.server()}
          | {:uplink, GenServer.server() | :none}
          | {:selectors_dir, Path.t()}
          | {:name, atom()}

  # contract: test/alavi/poller_test.exs "Pollers.start_link/1"
  @spec start_link([option()]) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @impl true
  def init(opts) do
    shared =
      for key <- [:sink, :clock, :raw_log, :status, :selectors_dir],
          do: {key, Keyword.fetch!(opts, key)}

    # No uplink to nudge (tests that read the sink) unless one is named.
    shared = [{:uplink, Keyword.get(opts, :uplink, :none)} | shared]
    {%Config{endpoints: endpoints}, follow} = config(Keyword.fetch!(opts, :config), shared)
    children = Enum.map(endpoints, &{Poller, [{:endpoint, &1} | shared]})
    Supervisor.init(children ++ follow, strategy: :one_for_one)
  end

  # In a supervisor's `init/1`, `self()` is the supervisor.
  defp config(%Config{} = config, _shared), do: {config, []}

  defp config({:keeper, keeper}, shared) do
    {config, _digest} = ConfigKeeper.current(keeper)
    status = Keyword.fetch!(shared, :status)
    {config, [{Applier, pollers: self(), keeper: keeper, shared: shared, status: status}]}
  end

  # contract: test/alavi/pollers/applier_test.exs "start_link/1"
  @doc "Each poller's child ID and pid, `:undefined` or `:restarting`."
  @spec pollers(Supervisor.supervisor()) ::
          [{{Poller, String.t(), :inet.port_number()}, pid() | :undefined | :restarting}]
  def pollers(pollers),
    do:
      for(
        {{Poller, _, _} = id, child, _, _} <- Supervisor.which_children(pollers),
        do: {id, child}
      )

  # contract: test/alavi/poller_test.exs "Pollers.log_latency/2"
  @doc """
  `Alavi.Poller.log_latency/2` on every poller, together; one that does not
  answer within `timeout` ms, or is not running, is passed over.
  """
  @spec log_latency(Supervisor.supervisor(), timeout()) :: :ok
  def log_latency(pollers, timeout) do
    pids = for {_id, pid} <- pollers(pollers), is_pid(pid), do: pid

    pids
    |> Task.async_stream(&logged(&1, timeout),
      timeout: :infinity,
      max_concurrency: max(length(pids), 1)
    )
    |> Stream.run()
  end

  defp logged(pid, timeout) do
    Poller.log_latency(pid, timeout)
  catch
    :exit, _reason -> :ok
  end

  # contract: test/alavi/read_on_demand_test.exs "Pollers.read_now/3"
  @doc """
  `Alavi.Poller.read_now/3` on the poller of the endpoint at `host` and
  `port`. A poller that exits before it replies gives `:poller_down`.
  """
  @spec read_now(
          Supervisor.supervisor(),
          {String.t(), :inet.port_number()},
          [1..247],
          String.t() | nil
        ) ::
          {:ok, reference()}
          | {:error,
             :unknown_endpoint
             | :polled_by_other_system
             | :restarting
             | :poller_down
             | :no_units
             | {:unknown_units, [term()]}
             | :busy
             | :retiring}
  def read_now(pollers, {host, port}, units, request_id \\ nil) do
    case List.keyfind(pollers(pollers), {Poller, host, port}, 0) do
      {_id, pid} when is_pid(pid) -> call(pid, units, request_id)
      {_id, :undefined} -> {:error, :polled_by_other_system}
      {_id, :restarting} -> {:error, :restarting}
      nil -> {:error, :unknown_endpoint}
    end
  end

  defp call(pid, units, request_id) do
    Poller.read_now(pid, units, request_id)
  catch
    :exit, _reason -> {:error, :poller_down}
  end

  # contract: test/alavi/intake_test.exs "Pollers.serials/1"
  @doc """
  `Alavi.Poller.serials/1` of every running poller, asked at once, by its
  endpoint's host and port. A poller that is not running, or exits before
  it replies, is absent.
  """
  @spec serials(Supervisor.supervisor()) ::
          %{{String.t(), :inet.port_number()} => %{(1..247) => String.t()}}
  def serials(pollers) do
    running =
      for {{Poller, host, port}, pid} <- pollers(pollers), is_pid(pid), do: {{host, port}, pid}

    running
    |> Task.async_stream(fn {endpoint, pid} -> {endpoint, serials_of(pid)} end,
      timeout: :infinity,
      max_concurrency: max(length(running), 1)
    )
    |> Enum.flat_map(fn
      {:ok, {_endpoint, nil}} -> []
      {:ok, found} -> [found]
    end)
    |> Map.new()
  end

  defp serials_of(pid) do
    Poller.serials(pid)
  catch
    :exit, _reason -> nil
  end
end
