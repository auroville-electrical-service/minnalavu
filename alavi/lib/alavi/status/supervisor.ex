defmodule Alavi.Status.Supervisor do
  @moduledoc """
  The status process and the status page's server, beside `Alavi.Collector`
  rather than inside it, so that their crash restarts nothing that polls or
  buffers. `Alavi.Application` starts it `:temporary`: should it give up, the
  collector goes on without a status. Should it not start at all, that is
  logged and it returns `:ignore`, so the collector still starts.

  `port` is the status page's, from the settings' `status.port`; the server
  binds 127.0.0.1 whatever it is (`Alavi.Status.Web`).
  """

  use Supervisor

  require Logger

  alias Alavi.{Config, Settings, Status}
  alias Alavi.Status.Web

  @type option ::
          {:status, [Status.option()]} | {:port, :inet.port_number()} | {:name, atom()}

  # contract: test/alavi/status_test.exs "Supervisor.start_link/1"
  @spec start_link([option()]) :: Supervisor.on_start()
  def start_link(opts) do
    case Supervisor.start_link(__MODULE__, opts, Keyword.take(opts, [:name])) do
      {:error, reason} ->
        Logger.error(
          "alavi status: neither the status page nor status.json will be kept, " <>
            "as the status did not start (#{inspect(reason)}); collecting goes on without it"
        )

        :ignore

      started ->
        started
    end
  end

  @doc "A release's options."
  @spec options(Settings.t(), Config.t(), String.t()) :: [option()]
  def options(%Settings{} = settings, %Config{} = config, version),
    do: [
      status: Status.options(settings, config, version),
      port: settings.status.port,
      name: __MODULE__
    ]

  @impl true
  def init(opts) do
    status = Keyword.fetch!(opts, :status)

    web = [
      port: Keyword.fetch!(opts, :port),
      status: Keyword.fetch!(status, :name),
      root: status |> Keyword.fetch!(:file) |> Path.dirname()
    ]

    Supervisor.init([{Status, status}, {Web, web}], strategy: :one_for_one)
  end
end
