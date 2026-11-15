defmodule Alavi.Uplink do
  @moduledoc """
  Sends the buffer's batches to the server, oldest first, and acknowledges each
  only once the server has stored it. One attempt is pending at a time; a
  nudge brings it forward only while the buffer was last found empty, never
  past a backoff.

  When the buffer is empty and no answer has come from the server for
  `heartbeat_ms`, it sends a heartbeat (`Alavi.Buffer.heartbeat/1`), so that
  it learns of pending jobs, and the server sees an idle collector, not a
  silent one. Every answer's `jobs` go to the `intake` (`Alavi.Intake`), and
  its `config_digest` to the `config` keeper (`Alavi.ConfigKeeper`), whose
  report each batch's backlog carries. With a keeper, the heartbeat interval
  (`heartbeat_ms/2`) and the endpoints the intake resolves serials against
  follow each config it applies (`Alavi.ConfigKeeper.subscribe/1`).
  """

  use GenServer

  require Logger

  alias Alavi.{Buffer, Config, ConfigKeeper, Intake, Status, Wire}
  alias Alavi.Buffer.Batch
  alias Alavi.Uplink.{HTTP, Response, Target}

  @type backoff :: %{min: pos_integer(), max: pos_integer()}

  @typedoc """
  `timeout_ms` bounds the connect and the answer of each POST. `intake` is
  `:none` where no jobs are run (tests); jobs an answer lists are then logged.
  `config` is `:none` for a collector that does not fetch its config: its
  backlog then has no `config`, and answers' digests are not looked at.
  `heartbeat_ms` is given only then, for with a keeper it is the config's.
  """
  @type option ::
          {:buffer, GenServer.server()}
          | {:target, Target.t()}
          | {:clock, (-> DateTime.t())}
          | {:idle_ms, pos_integer()}
          | {:heartbeat_ms, pos_integer()}
          | {:intake, Intake.t() | :none}
          | {:config, GenServer.server() | :none}
          | {:backoff_ms, backoff()}
          | {:timeout_ms, pos_integer()}
          | {:status, GenServer.server()}
          | {:name, GenServer.name()}

  # contract: test/alavi/uplink_test.exs "start_link/1"
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  # contract: test/alavi/collector_test.exs "start_link/1"
  @doc """
  Due after the shortest polling interval of any meter this collector polls,
  one round of the meter polled most often; with none, after `idle_ms`.
  """
  @spec heartbeat_ms(Config.t(), pos_integer()) :: pos_integer()
  def heartbeat_ms(%Config{endpoints: endpoints}, idle_ms) do
    endpoints
    |> Enum.reject(& &1.polled_by_other_system)
    |> Enum.flat_map(& &1.meters)
    |> Enum.map(& &1.interval_ms)
    |> Enum.min(fn -> idle_ms end)
  end

  @impl true
  def init(opts) do
    backoff = Keyword.fetch!(opts, :backoff_ms)
    idle_ms = Keyword.fetch!(opts, :idle_ms)
    keeper = Keyword.fetch!(opts, :config)
    {heartbeat_ms, intake} = polling(keeper, opts, idle_ms)

    state = %{
      buffer: Keyword.fetch!(opts, :buffer),
      target: Keyword.fetch!(opts, :target),
      clock: Keyword.fetch!(opts, :clock),
      idle_ms: idle_ms,
      heartbeat_ms: heartbeat_ms,
      intake: intake,
      config: keeper,
      answered: monotonic(),
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

  defp polling(:none, opts, _idle_ms),
    do: {Keyword.fetch!(opts, :heartbeat_ms), Keyword.fetch!(opts, :intake)}

  defp polling(keeper, opts, idle_ms) do
    if Keyword.has_key?(opts, :heartbeat_ms),
      do: raise(ArgumentError, "with a config keeper, the heartbeat follows its config")

    {config, _digest} = ConfigKeeper.subscribe(keeper)
    {heartbeat_ms(config, idle_ms), configured(Keyword.fetch!(opts, :intake), config)}
  end

  defp configured(:none, _config), do: :none
  defp configured(intake, config), do: Intake.configured(intake, config)

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

  # The next attempt takes the new heartbeat interval.
  def handle_info({:alavi_config, %Config{} = config, _digest}, state) do
    heartbeat_ms = heartbeat_ms(config, state.idle_ms)
    {:noreply, %{state | heartbeat_ms: heartbeat_ms, intake: configured(state.intake, config)}}
  end

  defp attempt(state) do
    {result, wait, state} =
      case Buffer.take(state.buffer) do
        {:ok, batch} -> batch |> send_batch(state) |> settle(batch, state)
        :empty -> empty(state, monotonic() - state.answered)
      end

    timer = make_ref()
    Process.send_after(self(), {:send, timer}, wait)
    Status.uplink(state.status, result, wait)
    %{state | timer: timer, idle: result == :empty}
  end

  defp empty(%{heartbeat_ms: every} = state, since) when since >= every do
    batch = Buffer.heartbeat(state.buffer)
    batch |> send_batch(state) |> beat(batch, state)
  end

  defp empty(state, since), do: {:empty, min(state.idle_ms, state.heartbeat_ms - since), state}

  defp beat({:ack, answer}, batch, state) do
    Logger.debug("alavi uplink: heartbeat #{batch.id} stored")
    {:empty, state.idle_ms, %{answered(answer, state) | wait: state.backoff.min}}
  end

  defp beat({_quarantine_or_retry, why}, batch, state) do
    Logger.warning(
      "alavi uplink: heartbeat #{batch.id} not sent, again in #{state.wait} ms: #{why}"
    )

    retry({:not_sent, batch.id, why}, state)
  end

  # Every answer lists the pending jobs; one naming unknown requests is about the batch sent.
  defp answered(answer, state) do
    unknown(answer)
    digest(state.config, answer)
    %{state | answered: monotonic(), intake: jobs(state.intake, answer, monotonic())}
  end

  defp digest(:none, _answer), do: :ok

  defp digest(keeper, %{"config_digest" => digest}) when is_binary(digest) do
    if digest =~ ~r/\A[0-9a-f]{64}\z/,
      do: ConfigKeeper.answered(keeper, digest),
      else: digest_missing(digest)
  end

  defp digest(_keeper, answer), do: digest_missing(answer["config_digest"])

  defp digest_missing(value),
    do:
      Logger.warning(
        "alavi uplink: the answer's config_digest is not a SHA-256 in lowercase hex: #{inspect(value)}"
      )

  defp jobs(intake, %{"jobs" => jobs}, now) when intake != :none,
    do: Intake.offer(intake, jobs, now)

  defp jobs(:none, %{"jobs" => jobs}, _now) do
    Logger.warning("alavi uplink: jobs listed, and no intake to run them: #{inspect(jobs)}")
    :none
  end

  defp jobs(intake, _answer, _now), do: intake

  defp unknown(%{"unknown_requests" => ids, "batch_id" => batch}),
    do:
      Logger.warning(
        "alavi uplink: batch #{batch} carried request ids the server does not know as this collector's: #{inspect(ids)}"
      )

  defp unknown(_answer), do: :ok

  defp send_batch(%Batch{} = batch, state) do
    backlog = Buffer.backlog(state.buffer)
    body = batch |> Wire.batch(state.clock.(), backlog, report(state.config)) |> JSON.encode!()
    state.target |> HTTP.post(body, state.timeout_ms) |> Response.decide(batch.id)
  end

  defp report(:none), do: :none
  defp report(keeper), do: ConfigKeeper.report(keeper)

  defp settle({:ack, answer}, batch, state) do
    state = answered(answer, state)

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

  defp monotonic, do: System.monotonic_time(:millisecond)

  defp summary(%{"readings" => readings, "missed_reads" => missed}),
    do: "readings #{inspect(readings)}, missed reads #{inspect(missed)}"

  defp summary(answer), do: inspect(answer)
end
