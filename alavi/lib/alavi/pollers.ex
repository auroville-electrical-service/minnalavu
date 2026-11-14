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
          | {:name, atom()}

  # contract: test/alavi/poller_test.exs "Pollers.start_link/1"
  @spec start_link([option()]) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @impl true
  def init(opts) do
    %Config{endpoints: endpoints} = Keyword.fetch!(opts, :config)
    shared = for key <- [:sink, :clock, :raw_log, :status], do: {key, Keyword.fetch!(opts, key)}
    children = Enum.map(endpoints, &{Poller, [{:endpoint, &1} | shared]})
    Supervisor.init(children, strategy: :one_for_one)
  end
end
