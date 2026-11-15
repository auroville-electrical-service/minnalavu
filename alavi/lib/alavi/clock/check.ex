defmodule Alavi.Clock.Check do
  @moduledoc """
  Measures the collector's clock against NTP servers (SNTP, `Alavi.Sntp`) and
  records each query as an `Alavi.ClockCheck` in the sink: at start, every
  `day_ms` of monotonic time, and after a step of the clock.

  A check asks the servers in their configured order, one query each, and
  stops at the first that answers; every query it sent is recorded, answered
  or not, so a server that never answers stays visible.

  A watch every `watch_ms` compares how far the OS clock (what
  `DateTime.utc_now/0` reads) moved with how far monotonic time did; a
  difference beyond `step_ms` is a step. A step is followed by a check, but
  by at most one per `step_gap_ms`: a step within that of the last
  step-triggered check waits out the rest of it.

  Reading never waits on it: it only records, and a sink that refuses (a full
  buffer) is logged and the check dropped.
  """

  use GenServer

  require Logger

  alias Alavi.{ClockCheck, Sink, Sntp, Status}

  @port 123
  @timeout_ms 5_000
  @watch_ms 60_000
  @step_ms 2_000
  @day_ms 24 * 60 * 60 * 1_000
  @step_gap_ms 10 * 60 * 1_000

  @typedoc """
  `clock` is the OS clock, at microseconds; `monotonic` is monotonic time in
  ms. `timeout_ms` bounds the wait for each reply.
  """
  @type option ::
          {:servers, [String.t(), ...]}
          | {:port, :inet.port_number()}
          | {:sink, Sink.t()}
          | {:status, GenServer.server()}
          | {:clock, (-> DateTime.t())}
          | {:monotonic, (-> integer())}
          | {:timeout_ms, pos_integer()}
          | {:watch_ms, pos_integer()}
          | {:step_ms, pos_integer()}
          | {:day_ms, pos_integer()}
          | {:step_gap_ms, pos_integer()}
          | {:name, GenServer.name()}

  # contract: test/alavi/clock/check_test.exs "start_link/1"
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc "A release's options but `sink` and `status`: port 123 and the fixed bounds."
  @spec options([String.t(), ...]) :: [option()]
  def options([_ | _] = servers) do
    [
      servers: servers,
      port: @port,
      clock: fn -> DateTime.utc_now(:microsecond) end,
      monotonic: fn -> System.monotonic_time(:millisecond) end,
      timeout_ms: @timeout_ms,
      watch_ms: @watch_ms,
      step_ms: @step_ms,
      day_ms: @day_ms,
      step_gap_ms: @step_gap_ms,
      name: __MODULE__
    ]
  end

  @impl true
  def init(opts) do
    state =
      Map.new(
        [:servers, :port, :sink, :status, :clock, :monotonic] ++
          [:timeout_ms, :watch_ms, :step_ms, :day_ms, :step_gap_ms],
        &{&1, Keyword.fetch!(opts, &1)}
      )

    {:ok, Map.merge(state, %{watched: nil, scheduled: nil, stepped: nil, pending: false}),
     {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state) do
    now = sample(state)
    state = check(%{state | watched: now, scheduled: now.monotonic}, :start)
    Process.send_after(self(), :watch, state.watch_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(:watch, state) do
    Process.send_after(self(), :watch, state.watch_ms)
    now = sample(state)
    state = %{state | watched: now, pending: state.pending or stepped?(state, now)}
    {:noreply, state |> after_step(now.monotonic) |> daily(now.monotonic)}
  end

  defp sample(state) do
    monotonic = state.monotonic.()
    %{os: DateTime.to_unix(state.clock.(), :millisecond), monotonic: monotonic}
  end

  defp stepped?(%{watched: before, step_ms: bound}, now) do
    step = now.os - before.os - (now.monotonic - before.monotonic)

    if abs(step) > bound do
      Logger.warning("alavi clock: the clock stepped by #{step} ms against monotonic time")
      true
    else
      false
    end
  end

  defp after_step(%{pending: true, stepped: at} = state, now)
       when is_nil(at) or now - at >= state.step_gap_ms,
       do: %{check(state, :step) | stepped: now, pending: false}

  defp after_step(state, _now), do: state

  defp daily(%{scheduled: at} = state, now) when now - at >= state.day_ms,
    do: %{check(state, :daily) | scheduled: now}

  defp daily(state, _now), do: state

  defp check(state, trigger) do
    checks = ask(state.servers, trigger, state, [])
    Enum.each(checks, &log/1)
    keep(state, checks)
    Status.clock_check(state.status, List.last(checks))
    state
  end

  defp ask([], _trigger, _state, done), do: Enum.reverse(done)

  defp ask([server | rest], trigger, state, done) do
    case query(server, trigger, state) do
      %ClockCheck{outcome: {:answered, _}} = check -> Enum.reverse([check | done])
      check -> ask(rest, trigger, state, [check | done])
    end
  end

  defp keep(state, checks) do
    case Sink.record(state.sink, checks) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("alavi clock: #{length(checks)} clock checks not kept: #{inspect(reason)}")
    end
  end

  defp query(server, trigger, state) do
    tried = state.clock.()

    case resolve(server) do
      {:ok, address} ->
        {t1, t4, outcome} = exchange(address, state)
        %ClockCheck{trigger: trigger, server: server, t1: t1, t4: t4, outcome: outcome}

      {:error, reason} ->
        Logger.warning("alavi clock: NTP server #{server} does not resolve: #{inspect(reason)}")

        %ClockCheck{
          trigger: trigger,
          server: server,
          t1: tried,
          t4: state.clock.(),
          outcome: :unreachable
        }
    end
  end

  defp resolve(server) do
    name = String.to_charlist(server)

    with {:error, _} <- :inet.parse_address(name),
         {:error, _} <- :inet.getaddr(name, :inet) do
      :inet.getaddr(name, :inet6)
    end
  end

  defp exchange(address, state) do
    family = if tuple_size(address) == 4, do: :inet, else: :inet6

    case :gen_udp.open(0, [:binary, family, active: false]) do
      {:ok, socket} ->
        try do
          send_and_wait(socket, address, state)
        after
          :gen_udp.close(socket)
        end

      {:error, reason} ->
        at = state.clock.()
        Logger.warning("alavi clock: cannot open a UDP socket: #{inspect(reason)}")
        {at, at, :unreachable}
    end
  end

  # A connected socket is given only the server's packets.
  defp send_and_wait(socket, address, state) do
    nonce = :crypto.strong_rand_bytes(8)
    t1 = state.clock.()

    with :ok <- :gen_udp.connect(socket, address, state.port),
         :ok <- :gen_udp.send(socket, Sntp.request(nonce)),
         {:ok, {_from, _port, packet}} <- :gen_udp.recv(socket, 0, state.timeout_ms) do
      {t1, state.clock.(), reply(address, Sntp.parse(packet, nonce))}
    else
      {:error, :timeout} ->
        {t1, state.clock.(), :timeout}

      {:error, reason} ->
        Logger.warning("alavi clock: #{:inet.ntoa(address)}: #{inspect(reason)}")
        {t1, state.clock.(), :unreachable}
    end
  end

  defp reply(address, {:ok, answer}) do
    {:answered,
     %{
       address: address,
       stratum: answer.stratum,
       leap: answer.leap,
       reference_id: answer.reference_id,
       t2: answer.received,
       t3: answer.sent
     }}
  end

  defp reply(address, {:error, {:kiss_of_death, code}}), do: {:kiss_of_death, address, code}

  defp reply(address, {:error, {:invalid, why}}) do
    Logger.warning("alavi clock: #{:inet.ntoa(address)} sent a reply that is not usable: #{why}")
    :invalid
  end

  defp log(%ClockCheck{outcome: {:answered, a}} = c) do
    Logger.info(
      "alavi clock: #{c.server} (#{:inet.ntoa(a.address)}, stratum #{a.stratum}) answered; " <>
        "offset #{ClockCheck.offset_ms(c)} ms (its clock minus the collector's)"
    )
  end

  defp log(%ClockCheck{} = c),
    do:
      Logger.warning(
        "alavi clock: #{c.trigger} check of #{c.server}: #{ClockCheck.outcome(c.outcome)}"
      )
end
