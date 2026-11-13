defmodule Alavi.Clock.Windows do
  @moduledoc """
  The clock status on Windows, asked of the Windows Time service every
  `refresh_ms` and cached, so `status/1` never runs a command.
  """

  use GenServer

  require Logger

  alias Alavi.Clock
  alias Alavi.Clock.W32tm

  @type query :: (-> {:ok, String.t()} | {:error, String.t()})

  @type option ::
          {:query, query()}
          | {:clock, (-> DateTime.t())}
          | {:refresh_ms, pos_integer()}
          | {:name, GenServer.name()}

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  # contract: test/alavi/clock/windows_test.exs "status/1"
  @spec status(GenServer.server()) :: Clock.status()
  def status(server), do: GenServer.call(server, :status)

  # contract: test/alavi/clock/windows_test.exs "w32tm/0"
  @spec w32tm() :: {:ok, String.t()} | {:error, String.t()}
  def w32tm do
    case System.cmd("w32tm", ["/query", "/status", "/verbose"], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, "w32tm exited with status #{code}: #{output}"}
    end
  rescue
    error in ErlangError -> {:error, "w32tm cannot be run: #{Exception.message(error)}"}
  end

  @impl true
  def init(opts) do
    state = %{
      query: Keyword.fetch!(opts, :query),
      clock: Keyword.fetch!(opts, :clock),
      refresh_ms: Keyword.fetch!(opts, :refresh_ms),
      status: Clock.unsynced(),
      task: nil,
      failing: false
    }

    {:ok, state, {:continue, :refresh}}
  end

  @impl true
  def handle_continue(:refresh, state), do: {:noreply, refresh(state)}

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  @impl true
  def handle_info(:refresh, state), do: {:noreply, refresh(state)}

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, answered(%{state | task: nil}, result)}
  end

  defp refresh(state) do
    state = abandon(state)
    Process.send_after(self(), :refresh, state.refresh_ms)
    %{state | task: Task.async(state.query)}
  end

  defp abandon(%{task: nil} = state), do: state

  defp abandon(%{task: task} = state) do
    _ = Task.shutdown(task, :brutal_kill)
    failed(%{state | task: nil}, "w32tm did not answer within #{state.refresh_ms} ms")
  end

  defp answered(state, {:ok, output}) do
    case W32tm.parse(output, state.clock.()) do
      {:ok, status} -> synced(state, W32tm.settle(state.status, status))
      {:error, :unrecognised} -> failed(state, "w32tm's answer is not recognised: #{output}")
    end
  end

  defp answered(state, {:error, reason}), do: failed(state, reason)

  defp synced(state, status) do
    if state.failing or status.source != state.status.source do
      Logger.info(
        "alavi clock: source #{status.source}, last synced #{inspect(status.last_sync_at)}"
      )
    end

    %{state | status: status, failing: false}
  end

  defp failed(%{failing: true} = state, _why), do: state

  defp failed(state, why) do
    Logger.warning("alavi clock: reporting the clock as unsynced: #{why}")
    %{state | status: Clock.unsynced(), failing: true}
  end
end
