defmodule Alavi.Application do
  @moduledoc false

  use Application

  # The collector's settings are read here and nowhere else; files they name
  # that do not load stop startup with the reason.
  @impl true
  def start(_type, _args) do
    with {:ok, children} <- children(Application.fetch_env!(:alavi, :collector)) do
      Supervisor.start_link(children, strategy: :one_for_one, name: Alavi.Supervisor)
    end
  end

  # Before the pollers stop, their latency so far goes to the log and the
  # buffer, which outlive them; a poller has a few seconds to finish the step
  # under way.
  @impl true
  def prep_stop(state) do
    if Process.whereis(Alavi.Pollers), do: Alavi.Pollers.log_latency(Alavi.Pollers, 5_000)
    state
  end

  # contract: test/alavi/application_test.exs "children/1"
  # The status first, so it sees the first rounds; :temporary, so that however
  # it fails it cannot use up this supervisor's restarts and stop the collector.
  @doc false
  @spec children(:disabled | Alavi.Settings.t()) ::
          {:ok, [Supervisor.child_spec() | {module(), term()}]} | {:error, String.t()}
  def children(:disabled), do: {:ok, []}

  def children(%Alavi.Settings{} = settings) do
    with {:ok, opts} <- Alavi.Collector.load(settings, :os.type()) do
      status = Alavi.Status.Supervisor.options(settings, opts[:config], version())

      {:ok,
       [
         Supervisor.child_spec({Alavi.Status.Supervisor, status}, restart: :temporary),
         {Alavi.Collector, opts}
       ]}
    end
  end

  defp version, do: :alavi |> Application.spec(:vsn) |> to_string()
end
