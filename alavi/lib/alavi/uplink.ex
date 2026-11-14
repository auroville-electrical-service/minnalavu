defmodule Alavi.Uplink do
  @moduledoc """
  Sends the buffer's batches to the server, oldest first, and acknowledges each
  only once the server has stored it. One attempt is pending at a time; a
  nudge brings it forward only while the buffer was last found empty, never
  past a backoff.
  """

  use GenServer

  require Logger

  alias Alavi.{Buffer, Status, Wire}
  alias Alavi.Buffer.Batch
  alias Alavi.Uplink.{HTTP, Response, Target}

  @type backoff :: %{min: pos_integer(), max: pos_integer()}

  @typedoc "`timeout_ms` bounds the connect and the answer of each POST."
  @type option ::
          {:buffer, GenServer.server()}
          | {:target, Target.t()}
          | {:clock, (-> DateTime.t())}
          | {:idle_ms, pos_integer()}
          | {:backoff_ms, backoff()}
          | {:timeout_ms, pos_integer()}
          | {:status, GenServer.server()}
          | {:name, GenServer.name()}

  # contract: test/alavi/uplink_test.exs "start_link/1"
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @impl true
  def init(opts) do
    backoff = Keyword.fetch!(opts, :backoff_ms)

    state = %{
      buffer: Keyword.fetch!(opts, :buffer),
      target: Keyword.fetch!(opts, :target),
      clock: Keyword.fetch!(opts, :clock),
      idle_ms: Keyword.fetch!(opts, :idle_ms),
      timeout_ms: Keyword.fetch!(opts, :timeout_ms),
      status: Keyword.fetch!(opts, :status),
      backoff: backoff,
      wait: backoff.min,
      timer: nil,
      idle: false
    }

    {:ok, state, {:continue, :send}}
  end

  @impl true
  def handle_continue(:send, state), do: {:noreply, attempt(state)}

  # contract: test/alavi/uplink_test.exs "nudge/1"
  @doc "Something new is in the buffer: send it now if the uplink is idle."
  @spec nudge(GenServer.server()) :: :ok
  def nudge(server), do: GenServer.cast(server, :nudge)

  @impl true
  def handle_cast(:nudge, %{idle: true} = state), do: {:noreply, attempt(state)}
  def handle_cast(:nudge, state), do: {:noreply, state}

  @impl true
  def handle_info({:send, timer}, %{timer: timer} = state), do: {:noreply, attempt(state)}

  # The attempt it was for came sooner, by a nudge.
  def handle_info({:send, _stale}, state), do: {:noreply, state}

  defp attempt(state) do
    {result, wait, state} =
      case Buffer.take(state.buffer) do
        {:ok, batch} -> batch |> send_batch(state) |> settle(batch, state)
        :empty -> {:empty, state.idle_ms, state}
      end

    timer = make_ref()
    Process.send_after(self(), {:send, timer}, wait)
    Status.uplink(state.status, result, wait)
    %{state | timer: timer, idle: result == :empty}
  end

  defp send_batch(%Batch{} = batch, state) do
    body = batch |> Wire.batch(state.clock.(), Buffer.backlog(state.buffer)) |> JSON.encode!()
    state.target |> HTTP.post(body, state.timeout_ms) |> Response.decide(batch.id)
  end

  defp settle({:ack, answer}, batch, state) do
    case Buffer.ack(state.buffer, batch.id) do
      :ok ->
        Logger.info("alavi uplink: batch #{batch.id} stored: #{summary(answer)}")
        now({:stored, batch.id}, state)

      {:error, reason} ->
        why = "stored but not deleted: #{inspect(reason)}"
        Logger.error("alavi uplink: batch #{batch.id} #{why}")
        retry({:not_sent, batch.id, why}, state)
    end
  end

  defp settle({:quarantine, why}, batch, state) do
    case Buffer.quarantine(state.buffer, batch.id, why) do
      :ok ->
        now({:quarantined, batch.id, why}, state)

      {:error, reason} ->
        why = "rejected (#{why}) and could not be set aside: #{inspect(reason)}"
        Logger.error("alavi uplink: batch #{batch.id} #{why}")
        retry({:not_sent, batch.id, why}, state)
    end
  end

  defp settle({:retry, why}, batch, state) do
    Logger.warning("alavi uplink: batch #{batch.id} not sent, again in #{state.wait} ms: #{why}")
    retry({:not_sent, batch.id, why}, state)
  end

  defp now(result, state), do: {result, 0, %{state | wait: state.backoff.min}}

  defp retry(result, state),
    do: {result, state.wait, %{state | wait: min(state.wait * 2, state.backoff.max)}}

  defp summary(%{"readings" => readings, "missed_reads" => missed}),
    do: "readings #{inspect(readings)}, missed reads #{inspect(missed)}"

  defp summary(answer), do: inspect(answer)
end
