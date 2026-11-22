defmodule Alavi.Control do
  @moduledoc """
  A planned stop, asked for by a file in `dir`: `rel\\windows\\stop.ps1` writes
  `quiesce` and waits for `quiesced` before it stops the service, so that the
  pollers stop in their own time rather than in the few seconds a stopping
  service leaves them.

  At start it writes `ready`, which tells the script this node answers, and
  removes any `quiesce` and `quiesced` left from before: a request is for the
  node that was running, and one obeyed at start would leave a collector that
  never polls. Every `check_ms` it looks for `quiesce`; once found, every
  poller retires (`Alavi.Pollers.stop/2`, waiting up to `quiesce_ms`), and
  `quiesced` records when, and how many were still running. It looks no more
  after. A directory it cannot use is logged and the collector runs on
  without it: a planned stop is then an ordinary one.
  """

  use GenServer

  require Logger

  alias Alavi.Pollers

  @check_ms 30_000
  # Below stop.ps1's default wait (180 s), so that it sees the answer.
  @quiesce_ms 120_000

  @type option ::
          {:dir, Path.t()}
          | {:pollers, Supervisor.supervisor()}
          | {:check_ms, pos_integer()}
          | {:quiesce_ms, pos_integer()}

  # contract: test/alavi/control_test.exs "start_link/1"
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    state = %{
      dir: Keyword.fetch!(opts, :dir),
      pollers: Keyword.fetch!(opts, :pollers),
      check_ms: Keyword.get(opts, :check_ms, @check_ms),
      quiesce_ms: Keyword.get(opts, :quiesce_ms, @quiesce_ms)
    }

    case ready(state.dir) do
      :ok ->
        Process.send_after(self(), :check, state.check_ms)
        {:ok, state}

      {:error, reason} ->
        Logger.warning(
          "alavi control: #{state.dir} not usable (#{inspect(reason)}); " <>
            "a planned stop is an ordinary one"
        )

        :ignore
    end
  end

  @impl true
  def handle_info(:check, state) do
    if File.exists?(path(state.dir, "quiesce")) do
      quiesce(state)
      {:noreply, state}
    else
      Process.send_after(self(), :check, state.check_ms)
      {:noreply, state}
    end
  end

  defp ready(dir) do
    with :ok <- File.mkdir_p(dir),
         :ok <- stale(dir, "quiesce"),
         :ok <- stale(dir, "quiesced") do
      File.write(path(dir, "ready"), now())
    end
  end

  defp stale(dir, name) do
    case File.rm(path(dir, name)) do
      :ok ->
        Logger.warning("alavi control: #{name} left from before this start removed")

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp quiesce(state) do
    Logger.info("alavi control: a planned stop asked; every poller retires")
    Pollers.stop(state.pollers, state.quiesce_ms)

    running =
      state.pollers |> Pollers.pollers() |> Enum.count(fn {_id, child} -> is_pid(child) end)

    answer = JSON.encode!(%{"at" => now(), "running" => running})

    case File.write(path(state.dir, "quiesced"), answer) do
      :ok ->
        Logger.info("alavi control: pollers retired, #{running} still running")

      {:error, reason} ->
        Logger.warning("alavi control: quiesced not written: #{inspect(reason)}")
    end
  end

  defp path(dir, name), do: Path.join(dir, name)

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
