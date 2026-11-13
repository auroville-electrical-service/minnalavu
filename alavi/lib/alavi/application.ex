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

  defp children(:disabled), do: {:ok, []}

  defp children(%Alavi.Settings{} = settings) do
    with {:ok, opts} <- Alavi.Collector.load(settings, :os.type()),
         do: {:ok, [{Alavi.Collector, opts}]}
  end
end
