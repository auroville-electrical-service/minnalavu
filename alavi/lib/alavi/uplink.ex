defmodule Alavi.Uplink do
  @moduledoc """
  Sends the buffer's batches to the server, oldest first, and acknowledges each
  only once the server has stored it.
  """

  use GenServer

  require Logger

  alias Alavi.{Buffer, Wire}
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
      backoff: backoff,
      wait: backoff.min
    }

    {:ok, state, {:continue, :send}}
  end

  @impl true
  def handle_continue(:send, state), do: {:noreply, attempt(state)}

  @impl true
  def handle_info(:send, state), do: {:noreply, attempt(state)}

  defp attempt(state) do
    case Buffer.take(state.buffer) do
      {:ok, batch} -> batch |> send_batch(state) |> settle(batch, state)
      :empty -> later(state, state.idle_ms)
    end
  end

  defp send_batch(%Batch{} = batch, state) do
    body = batch |> Wire.batch(state.clock.(), Buffer.backlog(state.buffer)) |> JSON.encode!()
    state.target |> HTTP.post(body, state.timeout_ms) |> Response.decide(batch.id)
  end

  defp settle({:ack, answer}, batch, state) do
    case Buffer.ack(state.buffer, batch.id) do
      :ok ->
        Logger.info("alavi uplink: batch #{batch.id} stored: #{summary(answer)}")
        now(state)

      {:error, reason} ->
        Logger.error("alavi uplink: batch #{batch.id} stored but not deleted: #{inspect(reason)}")
        retry(state)
    end
  end

  defp settle({:quarantine, why}, batch, state) do
    case Buffer.quarantine(state.buffer, batch.id, why) do
      :ok ->
        now(state)

      {:error, reason} ->
        Logger.error(
          "alavi uplink: batch #{batch.id} rejected (#{why}) and could not be set aside: #{inspect(reason)}"
        )

        retry(state)
    end
  end

  defp settle({:retry, why}, batch, state) do
    Logger.warning("alavi uplink: batch #{batch.id} not sent, again in #{state.wait} ms: #{why}")
    retry(state)
  end

  defp now(state) do
    send(self(), :send)
    %{state | wait: state.backoff.min}
  end

  defp retry(state),
    do: %{later(state, state.wait) | wait: min(state.wait * 2, state.backoff.max)}

  defp later(state, ms) do
    Process.send_after(self(), :send, ms)
    state
  end

  defp summary(%{"readings" => readings, "missed_reads" => missed}),
    do: "readings #{inspect(readings)}, missed reads #{inspect(missed)}"

  defp summary(answer), do: inspect(answer)
end
