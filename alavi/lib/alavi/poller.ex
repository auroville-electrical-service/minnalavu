defmodule Alavi.Poller do
  use GenServer

  require Logger

  alias Alavi.Config.{Endpoint, Meter}
  alias Alavi.{Decode, MissedRead, Reading, Sink}
  alias Alavi.Modbus.Client
  alias Alavi.Poller.{Policy, RawLog}
  alias Alavi.Profile.{Identity, Register}

  @typedoc "Wall clock for reading timestamps, UTC."
  @type clock :: (-> DateTime.t())

  @type option ::
          {:endpoint, Endpoint.t()}
          | {:sink, Sink.t()}
          | {:clock, clock()}
          | {:raw_log, RawLog.limits()}

  # contract: test/alavi/poller_test.exs "start_link/1"
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @spec child_spec([option()]) :: Supervisor.child_spec()
  def child_spec(opts) do
    %Endpoint{host: host, port: port} = Keyword.fetch!(opts, :endpoint)
    %{id: {__MODULE__, host, port}, start: {__MODULE__, :start_link, [opts]}}
  end

  @impl true
  def init(opts) do
    endpoint = Keyword.fetch!(opts, :endpoint)
    sink = Keyword.fetch!(opts, :sink)
    clock = Keyword.fetch!(opts, :clock)
    raw_log = RawLog.new("#{endpoint.host}:#{endpoint.port}", Keyword.fetch!(opts, :raw_log))
    start(endpoint, sink, clock, raw_log)
  end

  @impl true
  def handle_continue(:poll, state), do: {:noreply, poll_round(state)}

  @impl true
  def handle_info(:poll, state), do: {:noreply, poll_round(state)}

  defp start(%Endpoint{polled_by_other_system: true}, _sink, _clock, _raw_log), do: :ignore

  defp start(endpoint, sink, clock, raw_log) do
    now = now()

    state = %{
      endpoint: endpoint,
      sink: sink,
      clock: clock,
      raw_log: raw_log,
      client: nil,
      confirmed: MapSet.new(),
      down: nil,
      due: Map.new(endpoint.meters, &{&1.unit_id, now}),
      backoff: endpoint.reconnect_backoff_ms.min,
      reconnect_at: now
    }

    {:ok, state, {:continue, :poll}}
  end

  defp poll_round(state) do
    started = now()
    state = log_raw(state, &RawLog.flush(&1, started))
    due = Enum.filter(state.endpoint.meters, &(state.due[&1.unit_id] <= started))
    state = Enum.reduce(due, %{state | down: nil}, &poll_meter/2)
    due_at = Map.merge(state.due, Map.new(due, &{&1.unit_id, started + &1.interval_ms}))
    next = due_at |> Map.values() |> Enum.min()
    Process.send_after(self(), :poll, max(next - now(), 0))
    %{state | due: due_at}
  end

  defp poll_meter(meter, state) do
    {events, state} =
      case identify(meter, state) do
        {:ok, state} -> read_registers(meter, state)
        {{:missed, reason, n}, state} -> {missed_all(state, meter, reason, n), state}
      end

    # A refusal is the sink's to report (see `Alavi.Sink`); the round goes on.
    _kept_or_refused = Sink.record(state.sink, events)
    state
  end

  defp read_registers(meter, state) do
    skip = if state.down, do: {:unreachable, state.down}

    {events, {state, _skip}} =
      Enum.map_reduce(meter.profile.registers, {state, skip}, &register(&1, &2, meter))

    {events, state}
  end

  # The attempts were made once, for the meter: they count on its first register.
  defp missed_all(state, meter, reason, n) do
    [first | rest] = meter.profile.registers

    [
      missed(state, meter, first, reason, n)
      | Enum.map(rest, &missed(state, meter, &1, reason, 0))
    ]
  end

  # An unreachable endpoint is left to `read_registers/2`, which records it.
  defp identify(%Meter{unit_id: unit, profile: profile}, state) do
    cond do
      state.down != nil -> {:ok, state}
      Identity.empty?(profile.identity) -> {:ok, state}
      MapSet.member?(state.confirmed, unit) -> {:ok, state}
      true -> check_identity(unit, profile.identity, state)
    end
  end

  defp check_identity(unit, identity, state) do
    identity
    |> Identity.reads()
    |> Enum.reduce_while({%{}, state}, fn {check, table, address, count}, {results, state} ->
      case read_words(state, {unit, table, address, count}, 1) do
        {{:ok, words, _n}, state} ->
          {:cont, {Map.put(results, check, {:ok, words}), state}}

        {{:skip_register, error, _n}, state} ->
          {:cont, {Map.put(results, check, {:error, error}), state}}

        {{:skip_meter, reason, n}, state} ->
          {:halt, {{:missed, reason, n}, state}}
      end
    end)
    |> case do
      {{:missed, _reason, _n} = missed, state} -> {missed, state}
      {results, state} -> judged(Identity.verdict(identity, results), unit, state)
    end
  end

  defp judged(:ok, unit, state),
    do: {:ok, %{state | confirmed: MapSet.put(state.confirmed, unit)}}

  defp judged({:mismatch, detail}, unit, state) do
    Logger.warning("alavi poller #{label(state)} unit #{unit}: profile mismatch: #{detail}")
    {{:missed, {:profile_mismatch, detail}, 0}, state}
  end

  defp judged({:error, error}, _unit, state), do: {{:missed, error, 0}, state}

  defp label(%{endpoint: %Endpoint{host: host, port: port}}), do: "#{host}:#{port}"

  defp register(reg, {state, nil}, meter) do
    read = {meter.unit_id, reg.table, reg.address, Register.word_count(reg)}

    case read_words(state, read, 1) do
      {{:ok, words, n}, state} -> {decoded(state, meter, reg, words, n), {state, nil}}
      {{:skip_register, error, n}, state} -> {missed(state, meter, reg, error, n), {state, nil}}
      {{:skip_meter, reason, n}, state} -> {missed(state, meter, reg, reason, n), {state, reason}}
    end
  end

  defp register(reg, {state, skip}, meter),
    do: {missed(state, meter, reg, skip, 0), {state, skip}}

  defp decoded(state, meter, reg, words, n) do
    case Decode.value(reg, words) do
      {:ok, value} -> reading(state, meter, reg, words, value)
      {:error, reason} -> %{missed(state, meter, reg, {:decode, reason}, n) | raw_words: words}
    end
  end

  # One read under `Alavi.Poller.Policy`, attempt `n`.
  defp read_words(state, {unit, table, address, count} = read, n) do
    case connected(state) do
      {:ok, state} ->
        {result, state} =
          state.client |> Client.read(unit, table, address, count) |> anomalies(state)

        retried(result, state, read, n)

      {:error, reason, state} ->
        {{:skip_meter, {:unreachable, reason}, n}, state}
    end
  end

  defp retried({:ok, words, client}, state, _read, n) do
    {{:ok, words, n}, %{state | client: client, backoff: state.endpoint.reconnect_backoff_ms.min}}
  end

  defp retried({:error, error, client}, state, read, n) do
    state = %{state | client: client}

    case Policy.next(error, n, state.endpoint) do
      :retry ->
        read_words(state, read, n + 1)

      {:retry_after, ms} ->
        Process.sleep(ms)
        read_words(state, read, n + 1)

      :skip_meter ->
        {{:skip_meter, error, n}, state}

      :skip_register ->
        {{:skip_register, error, n}, state}
    end
  end

  defp anomalies({tag, value, client}, state) do
    {anomalies, client} = Client.take_anomalies(client)
    {{tag, value, client}, log_raw(state, &RawLog.note(&1, anomalies, now()))}
  end

  defp log_raw(state, step) do
    {lines, raw_log} = step.(state.raw_log)
    Enum.each(lines, &Logger.warning/1)
    %{state | raw_log: raw_log}
  end

  defp connected(%{client: %Client{socket: socket}} = state) when socket != nil, do: {:ok, state}

  defp connected(%{endpoint: endpoint} = state) do
    Process.sleep(max(state.reconnect_at - now(), 0))
    result = Client.connect(endpoint.host, endpoint.port, endpoint.framing, client_opts(endpoint))

    state = %{
      state
      | reconnect_at: now() + state.backoff,
        backoff: Policy.backoff(state.backoff, endpoint.reconnect_backoff_ms)
    }

    case result do
      {:ok, client} ->
        {:ok, %{state | client: client, confirmed: MapSet.new()}}

      {:error, reason} ->
        Logger.warning(
          "alavi: cannot connect to #{endpoint.host}:#{endpoint.port}: #{inspect(reason)}"
        )

        {:error, reason, %{state | client: nil, down: reason}}
    end
  end

  defp client_opts(%Endpoint{framing: :tcp} = e),
    do: [timeout: e.timeout_ms, max_timeouts: e.max_timeouts]

  defp client_opts(%Endpoint{framing: :rtu_over_tcp} = e), do: [timeout: e.timeout_ms]

  defp reading(state, %Meter{} = meter, %Register{} = reg, words, value) do
    %Reading{
      endpoint: endpoint_ref(state.endpoint),
      unit_id: meter.unit_id,
      meter_serial: meter.serial,
      profile: meter.profile.name,
      register_key: reg.key,
      timestamp: state.clock.(),
      raw_words: words,
      value: value,
      unit: reg.unit
    }
  end

  defp missed(state, %Meter{} = meter, %Register{} = reg, reason, attempts) do
    %MissedRead{
      endpoint: endpoint_ref(state.endpoint),
      unit_id: meter.unit_id,
      meter_serial: meter.serial,
      profile: meter.profile.name,
      register_key: reg.key,
      timestamp: state.clock.(),
      reason: reason,
      attempts: attempts,
      raw_words: nil
    }
  end

  defp endpoint_ref(%Endpoint{host: host, port: port}), do: %{host: host, port: port}

  defp now, do: System.monotonic_time(:millisecond)
end
