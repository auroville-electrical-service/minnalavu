defmodule Alavi.Pollers do
  use Supervisor

  alias Alavi.{Config, Poller, Sink}
  alias Alavi.Poller.RawLog

  @type option ::
          {:config, Config.t()}
          | {:sink, Sink.t()}
          | {:clock, Poller.clock()}
          | {:raw_log, RawLog.limits()}
          | {:status, GenServer.server()}
          | {:uplink, GenServer.server() | :none}
          | {:name, atom()}

  # contract: test/alavi/poller_test.exs "Pollers.start_link/1"
  @spec start_link([option()]) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @impl true
  def init(opts) do
    %Config{endpoints: endpoints} = Keyword.fetch!(opts, :config)
    shared = for key <- [:sink, :clock, :raw_log, :status], do: {key, Keyword.fetch!(opts, key)}
    # No uplink to nudge (tests that read the sink) unless one is named.
    shared = [{:uplink, Keyword.get(opts, :uplink, :none)} | shared]
    children = Enum.map(endpoints, &{Poller, [{:endpoint, &1} | shared]})
    Supervisor.init(children, strategy: :one_for_one)
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
             | {:unknown_units, [term()]}}
  def read_now(pollers, {host, port}, units, request_id \\ nil) do
    case List.keyfind(Supervisor.which_children(pollers), {Poller, host, port}, 0) do
      {_id, pid, _type, _modules} when is_pid(pid) -> call(pid, units, request_id)
      {_id, :undefined, _type, _modules} -> {:error, :polled_by_other_system}
      {_id, :restarting, _type, _modules} -> {:error, :restarting}
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
      for {{Poller, host, port}, pid, _, _} <- Supervisor.which_children(pollers),
          is_pid(pid),
          do: {{host, port}, pid}

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
