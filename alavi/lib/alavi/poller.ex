defmodule Alavi.Poller do
  @moduledoc """
  Polls one endpoint's meters. Each round, per meter: the identity, then the
  registers, recorded to the sink. Then, once every meter's readings are
  recorded, the firmware names of each meter whose identity was read, when
  `Alavi.Poller.Names` says they are due, unless the meter stopped answering
  during its register reads or the endpoint went down in the round.

  A round is an `Alavi.Poller.Job`, run one step per `:step` message, so the
  mailbox is served between steps. Each meter's names are a step of their
  own: a names read is as many reads as a meter's registers, so no step is
  longer than a meter's. `Alavi.Poller.Schedule` chooses, from the queue of
  jobs, what each message does. One wake-up is outstanding at a time: a
  `:step` message, or the poll timer while nothing is due.

  A read on demand (`read_now/2`) is a job of its own, run before the rest of
  a round under way, which then resumes where it stopped, unless a meter is
  overdue by its interval (`Alavi.Poller.Schedule.next/4`); it leaves when each
  meter is next due as it was. Its events go to the status page as reads, not
  as a round (`Alavi.Status.on_demand/2`), so that a round's outcomes stay a
  whole chain's, and once they are recorded the uplink is nudged
  (`Alavi.Uplink.nudge/1`).

  An owed selector restore (`Alavi.Selectors.Session.restore/3`), found on
  disk when the poller starts, or left by a session, runs before any other
  job. One that fails is retried after a backoff (the endpoint's reconnect
  backoff, doubling), at once when the endpoint was unreachable and the
  connection comes back; meanwhile rounds and reads on demand go on, and
  the status shows the endpoint faulted (`Alavi.Status.selectors/3`). It
  records no readings and no missed reads.

  Each request's round trip, from send to reply, not the connect, counts in
  its meter's `Alavi.Poller.Latency`: shown on the status page after each
  job (`Alavi.Status.latency/3`), and logged a line per meter when a UTC day
  ends, and on `log_latency/2`.
  """

  use GenServer

  require Logger

  alias Alavi.Config.{Endpoint, Meter}
  alias Alavi.{Decode, FirmwareRead, MissedRead, Reading, Sink, Status, Uplink}
  alias Alavi.Modbus.Client
  alias Alavi.Poller.{Job, Latency, Names, Policy, RawLog, Schedule}
  alias Alavi.Profile.{Firmware, Identity, Register}
  alias Alavi.Selectors.{Session, Store}

  @typedoc "Wall clock for reading timestamps, UTC."
  @type clock :: (-> DateTime.t())

  @type option ::
          {:endpoint, Endpoint.t()}
          | {:sink, Sink.t()}
          | {:clock, clock()}
          | {:raw_log, RawLog.limits()}
          | {:status, GenServer.server()}
          | {:uplink, GenServer.server() | :none}
          | {:selectors_dir, Path.t()}

  # contract: test/alavi/poller_test.exs "start_link/1"
  # contract: test/alavi/restore_test.exs "start_link/1"
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  # contract: test/alavi/read_on_demand_test.exs "read_now/2"
  @doc """
  Queue a read on demand of the meters with these unit IDs, or `:busy` past
  the bound of `Alavi.Poller.Schedule.queue_read/2`. It runs next, once the
  step under way ends, unless a round is overdue, and the caller is then sent
  `{:alavi_read, ref, events}`: the readings and missed reads it recorded,
  in the order read. The reply waits for that step.

  The caller is not monitored: if it is gone by then, the read still runs
  and its events are recorded like a round's; only the answer is lost.
  Its readings and missed reads carry `request_id`.
  """
  @spec read_now(GenServer.server(), [1..247], String.t() | nil) ::
          {:ok, reference()} | {:error, :no_units | {:unknown_units, [term()]} | :busy}
  def read_now(server, units, request_id \\ nil),
    do: GenServer.call(server, {:read_now, units, request_id}, :infinity)

  # contract: test/alavi/intake_test.exs "Pollers.serials/1"
  @doc """
  The serial last read at each unit since the poller started, by unit ID;
  a unit none was read at is absent. The reply waits for the step under way.
  """
  @spec serials(GenServer.server()) :: %{(1..247) => String.t()}
  def serials(server), do: GenServer.call(server, :serials, :infinity)

  # contract: test/alavi/poller_test.exs "Pollers.log_latency/2"
  @doc """
  Log each meter's latency for the day so far, as when a day ends: for a
  collector about to stop, whose latency is otherwise lost. The reply waits
  for the step under way.
  """
  @spec log_latency(GenServer.server(), timeout()) :: :ok
  def log_latency(server, timeout), do: GenServer.call(server, :log_latency, timeout)

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
    feeds = {sink, Keyword.fetch!(opts, :status), Keyword.fetch!(opts, :uplink)}
    start(endpoint, feeds, clock, {raw_log, Keyword.fetch!(opts, :selectors_dir)})
  end

  @impl true
  def handle_continue(:poll, state), do: {:noreply, wake(state)}

  @impl true
  def handle_call({:read_now, units, request_id}, {pid, _tag}, state) do
    ref = make_ref()

    with {:ok, job} <-
           Job.read_on_demand(state.endpoint.meters, units, now(), {pid, ref}, request_id),
         {:ok, queue} <- Schedule.queue_read(state.queue, job) do
      queued(%{state | queue: queue}, ref)
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call(:serials, _from, state), do: {:reply, state.serials, state}

  def handle_call(:log_latency, _from, state),
    do: {:reply, log_days(state, "before stopping"), state}

  @impl true
  def handle_info(:step, state), do: {:noreply, wake(state)}

  def handle_info({:poll, timer}, %{timer: timer} = state),
    do: {:noreply, wake(%{state | timer: nil})}

  # A timer whose wake-up came another way: nothing to do.
  def handle_info({:poll, _stale}, state), do: {:noreply, state}

  # A connect timeout that races the connect can leave gen_tcp's timer message
  # behind (`inet:stop_timer/1` flushes it with `after 0`); it means nothing here.
  def handle_info({:timeout, _timer, :inet}, state), do: {:noreply, state}

  defp start(%Endpoint{polled_by_other_system: true}, _feeds, _clock, _logs), do: :ignore

  defp start(endpoint, {sink, status, uplink}, clock, {raw_log, selectors_dir}) do
    now = now()

    state = %{
      endpoint: endpoint,
      sink: sink,
      status: status,
      uplink: uplink,
      clock: clock,
      raw_log: raw_log,
      client: nil,
      queue: [],
      job: nil,
      selectors_dir: selectors_dir,
      restore: nil,
      timer: nil,
      due: Map.new(endpoint.meters, &{&1.unit_id, now}),
      names: Map.new(endpoint.meters, &{&1.unit_id, Names.new()}),
      latency: Map.new(endpoint.meters, &{&1.unit_id, Latency.new()}),
      today: nil,
      serials: %{},
      backoff: endpoint.reconnect_backoff_ms.min,
      reconnect_at: now
    }

    {:ok, owed_at_start(state, now), {:continue, :poll}}
  end

  defp owed_at_start(state, now) do
    case Store.owed(state.selectors_dir, endpoint_ref(state.endpoint)) do
      :none ->
        state

      owed ->
        Logger.warning(
          "alavi poller #{label(state)}: a selector restore is owed: #{inspect(owed)}"
        )

        Status.selectors(state.status, endpoint_ref(state.endpoint), {:owed, "found at start", 0})
        owe_restore(state, now)
    end
  end

  defp owe_restore(state, at) do
    restore = state.restore || %{attempts: 0, backoff: state.endpoint.reconnect_backoff_ms.min}
    %{state | queue: Schedule.restore(state.queue, at, :backoff), restore: restore}
  end

  # Waiting on the timer, wake now and leave the timer stale; with no timer a
  # `:step` is already on its way, and a second would break the one wake-up.
  # No test shows it: a second `:step` reorders nothing (the schedule picks
  # each step), it only delays later calls in the mailbox by a step.
  defp queued(%{timer: nil} = state, ref), do: {:reply, {:ok, ref}, state}
  defp queued(state, ref), do: {:reply, {:ok, ref}, %{state | timer: nil}, {:continue, :poll}}

  defp wake(state), do: state |> act() |> rearm()

  defp act(state) do
    case decide(state) do
      {:step, job, rest} -> run(job, %{state | queue: rest})
      {:start, round} -> begin_round(round, state)
      {:wait, _ms} -> state
    end
  end

  defp rearm(state) do
    case decide(state) do
      {:wait, ms} ->
        timer = make_ref()
        Process.send_after(self(), {:poll, timer}, ms)
        %{state | timer: timer}

      _work ->
        send(self(), :step)
        state
    end
  end

  defp decide(state), do: Schedule.next(state.queue, now(), state.due, state.endpoint.meters)

  defp begin_round(%Job{started: started} = round, state) do
    state = log_raw(state, &RawLog.flush(&1, started))
    %{state | queue: state.queue ++ [round]}
  end

  defp run(%Job{kind: :restore} = job, state) do
    state = %{dated(state) | job: job}

    case connected(state) do
      {:ok, state} ->
        reply = Session.restore(state.client, state.selectors_dir, endpoint_ref(state.endpoint))
        {reply, state} = anomalies(reply, state)
        restored(reply, %{state | job: nil})

      {:error, reason, state} ->
        restore_failed(%{state | job: nil}, {:unreachable, reason})
    end
  end

  # The job is `state.job` while its step runs; resumed, it goes back at the head.
  defp run(job, state) do
    state = step(Job.next(job), %{dated(state) | job: job})

    case Job.next(state.job) do
      :done -> done(state)
      _step -> %{state | queue: [state.job | state.queue], job: nil}
    end
  end

  defp step({:meter, meter}, state) do
    {events, identified, state} = poll_meter(meter, state)
    %{state | job: Job.polled(state.job, events, identified)}
  end

  defp step({:names, identified}, state) do
    state = names(identified, state)
    %{state | job: Job.named(state.job)}
  end

  defp done(%{job: %Job{kind: :poll_round} = job} = state) do
    Status.round(state.status, Job.events(job))
    latency(state)
    %{state | due: Schedule.after_round(state.due, job), job: nil}
  end

  defp done(%{job: %Job{kind: :read_on_demand, requester: {pid, ref}} = job} = state) do
    events = Job.events(job)
    Status.on_demand(state.status, events)
    latency(state)
    nudge(state.uplink)
    send(pid, {:alavi_read, ref, events})
    %{state | job: nil}
  end

  defp restored({:ok, outcome, client}, state) do
    Logger.info("alavi poller #{label(state)}: #{restore_line(outcome)}")
    Status.selectors(state.status, endpoint_ref(state.endpoint), :restored)
    %{state | client: client, restore: nil}
  end

  defp restored({:error, reason, client}, state),
    do: restore_failed(%{state | client: client}, reason)

  defp restore_line(:restored), do: "selectors restored and read back; nothing owed"
  defp restore_line(:none), do: "the owed selector restore record is gone; nothing owed"

  defp restore_failed(state, reason) do
    %{attempts: attempts, backoff: backoff} = state.restore
    attempts = attempts + 1

    Logger.warning(
      "alavi poller #{label(state)}: selector restore failed (attempt #{attempts}), " <>
        "again in #{backoff} ms; polls go on: #{inspect(reason)}"
    )

    Status.selectors(
      state.status,
      endpoint_ref(state.endpoint),
      {:owed, inspect(reason), attempts}
    )

    restore = %{
      attempts: attempts,
      backoff: Policy.backoff(backoff, state.endpoint.reconnect_backoff_ms)
    }

    held = if match?({:unreachable, _}, reason), do: :connection, else: :backoff
    %{state | queue: Schedule.restore(state.queue, now() + backoff, held), restore: restore}
  end

  defp nudge(:none), do: :ok
  defp nudge(uplink), do: Uplink.nudge(uplink)

  # The meter, with what it reported, when identified, for its names step.
  defp poll_meter(meter, state) do
    case identify(meter, state) do
      {{:ok, seen}, state} ->
        state = serial_read(state, meter, seen.serial)
        {events, skip, state} = read_registers(meter, seen, state)
        recorded(events, state)
        {events, {meter, seen, skip}, state}

      {{:missed, reason, n, serial}, state} ->
        state = serial_read(state, meter, serial)
        events = missed_all(state, meter, serial, reason, n)
        recorded(events, state)
        {events, nil, state}
    end
  end

  defp serial_read(state, _meter, nil), do: state

  defp serial_read(state, %Meter{unit_id: unit}, serial),
    do: %{state | serials: Map.put(state.serials, unit, serial)}

  # A refusal is the sink's to report (see `Alavi.Sink`); the round goes on.
  defp recorded(events, state), do: Sink.record(state.sink, events)

  defp read_registers(meter, seen, state) do
    {events, {state, skip}} =
      Enum.map_reduce(meter.profile.registers, {state, nil}, &register(&1, &2, meter, seen))

    {events, skip, state}
  end

  # After every meter's readings in the round are recorded, so that no reading
  # waits on the names, and a names read that fails costs no meter its readings.
  defp names({%Meter{profile: %{firmware: nil}}, _seen, _skip}, state), do: state

  defp names({%Meter{unit_id: unit} = meter, seen, skip}, state) do
    names = Names.observe(state.names[unit], {seen.serial, seen.product_code}, state.clock.())

    {names, state} =
      if names.due and skip == nil,
        do: read_names(meter, seen, names, state),
        else: {names, state}

    %{state | names: Map.put(state.names, unit, names)}
  end

  defp read_names(meter, _seen, names, %{job: %Job{down: down}} = state) when down != nil do
    not_read(state, meter, {:unreachable, down})
    {names, state}
  end

  defp read_names(meter, seen, names, state) do
    case name_words(meter, state) do
      {{:ok, results}, state} ->
        read = firmware_read(state, meter, seen, results)
        Status.firmware(state.status, read)
        {sent(Names.read(names, read.timestamp), read, state), state}

      {{:error, reason}, state} ->
        not_read(state, meter, reason)
        {names, state}
    end
  end

  defp name_words(%Meter{unit_id: unit, profile: %{firmware: firmware}}, state) do
    firmware
    |> Firmware.reads()
    |> Enum.reduce_while({{:ok, %{}}, state}, fn {name, table, address, count},
                                                 {{:ok, acc}, state} ->
      case name_result(read_words(state, {unit, table, address, count}, 1)) do
        {{:ok, result}, state} -> {:cont, {{:ok, Map.put(acc, name, result)}, state}}
        {{:error, reason}, state} -> {:halt, {{:error, reason}, state}}
      end
    end)
  end

  # Exception 02, illegal data address: the meter has no such register, so the
  # name is not given. Any other refusal may pass, so the read is tried again.
  defp name_result({{:ok, words, _n}, state}), do: {{:ok, {:ok, words}}, state}

  defp name_result({{:skip_register, {:exception, 2} = error, _n}, state}),
    do: {{:ok, error}, state}

  defp name_result({{_skip, reason, _n}, state}), do: {{:error, reason}, state}

  defp not_read(state, meter, reason),
    do: warn(state, meter, "firmware names not read, again next round: #{inspect(reason)}")

  defp firmware_read(state, meter, seen, results) do
    names = Map.new(results, fn {name, result} -> {name, name(state, meter, name, result)} end)

    struct!(
      FirmwareRead,
      Map.merge(names, %{
        endpoint: endpoint_ref(state.endpoint),
        unit_id: meter.unit_id,
        meter_serial: seen.serial,
        product_code: seen.product_code,
        timestamp: state.clock.()
      })
    )
  end

  defp name(state, meter, name, {:ok, words}) do
    case Firmware.decode(Map.fetch!(meter.profile.firmware, name), words) do
      {:ok, text} -> text
      {:error, why} -> name(state, meter, name, {:decode, why})
    end
  end

  defp name(state, meter, name, why) do
    warn(state, meter, "firmware name #{name} not given, sent as null: #{inspect(why)}")
    nil
  end

  defp sent(names, read, state) do
    cond do
      not Names.changed?(names, read) -> names
      recorded([read], state) == :ok -> Names.sent(names, read)
      true -> Names.refused(names)
    end
  end

  defp warn(state, meter, message),
    do: Logger.warning("alavi poller #{label(state)} unit #{meter.unit_id}: #{message}")

  # The attempts were made once, for the meter: they count on its first register.
  defp missed_all(state, meter, serial, reason, n) do
    [first | rest] = meter.profile.registers

    [
      missed(state, meter, serial, first, reason, n)
      | Enum.map(rest, &missed(state, meter, serial, &1, reason, 0))
    ]
  end

  # Read every round, so each reading carries what the meter reported in its own round.
  defp identify(_meter, %{job: %Job{down: down}} = state) when down != nil,
    do: {{:missed, {:unreachable, down}, 0, nil}, state}

  defp identify(meter, state) do
    case read_identity(meter, state) do
      {{:missed, _reason, _n, _serial} = missed, state} -> {missed, state}
      {results, state} -> judged(Identity.verdict(meter.profile.identity, results), meter, state)
    end
  end

  defp read_identity(%Meter{unit_id: unit, profile: %{identity: identity}}, state) do
    identity
    |> Identity.reads()
    |> Enum.reduce_while({%{}, state}, &identity_read(&1, &2, unit, identity))
  end

  defp identity_read({check, table, address, count}, {results, state}, unit, identity) do
    case read_words(state, {unit, table, address, count}, 1) do
      {{:ok, words, _n}, state} ->
        {:cont, {Map.put(results, check, {:ok, words}), state}}

      {{:skip_register, error, _n}, state} ->
        {:cont, {Map.put(results, check, {:error, error}), state}}

      {{:skip_meter, reason, n}, state} ->
        serial = Identity.observed(identity, results).serial
        {:halt, {{:missed, reason, n, serial}, state}}
    end
  end

  defp judged({outcome, observed}, meter, state) do
    compare_serial(meter, observed.serial, state)
    outcome(outcome, observed, meter, state)
  end

  defp outcome(:ok, %{serial: serial, product_code: code} = seen, _meter, state)
       when is_binary(serial) and is_binary(code),
       do: {{:ok, seen}, state}

  defp outcome({:mismatch, detail}, observed, meter, state) do
    Logger.warning(
      "alavi poller #{label(state)} unit #{meter.unit_id}: profile mismatch: #{detail}"
    )

    {{:missed, {:profile_mismatch, detail}, 0, observed.serial}, state}
  end

  defp outcome({:error, error}, observed, _meter, state),
    do: {{:missed, error, 0, observed.serial}, state}

  defp compare_serial(%Meter{serial: expected} = meter, read, state)
       when is_binary(expected) and is_binary(read) and expected != read do
    Logger.warning(
      "alavi poller #{label(state)} unit #{meter.unit_id}: serial #{inspect(read)} read, " <>
        "#{inspect(expected)} configured; its readings go under the serial read"
    )
  end

  defp compare_serial(_meter, _read, _state), do: :ok

  defp label(%{endpoint: %Endpoint{host: host, port: port}}), do: "#{host}:#{port}"

  defp register(reg, {state, nil}, meter, seen) do
    read = {meter.unit_id, reg.table, reg.address, Register.word_count(reg)}

    case read_words(state, read, 1) do
      {{:ok, words, n}, state} ->
        {decoded(state, meter, seen, reg, words, n), {state, nil}}

      {{:skip_register, error, n}, state} ->
        {missed(state, meter, seen.serial, reg, error, n), {state, nil}}

      {{:skip_meter, reason, n}, state} ->
        {missed(state, meter, seen.serial, reg, reason, n), {state, reason}}
    end
  end

  defp register(reg, {state, skip}, meter, seen),
    do: {missed(state, meter, seen.serial, reg, skip, 0), {state, skip}}

  defp decoded(state, meter, seen, reg, words, n) do
    case Decode.value(reg, words) do
      {:ok, value} ->
        reading(state, meter, seen, reg, value)

      {:error, reason} ->
        %{missed(state, meter, seen.serial, reg, {:decode, reason}, n) | raw_words: words}
    end
  end

  # One read under `Alavi.Poller.Policy`, attempt `n`.
  defp read_words(state, {unit, table, address, count} = read, n) do
    case connected(state) do
      {:ok, state} ->
        sent = now()
        reply = Client.read(state.client, unit, table, address, count)
        state = timed(state, unit, n, now() - sent, reply)
        {result, state} = anomalies(reply, state)
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

  defp timed(state, unit, n, ms, reply) do
    record = &Latency.record(&1, state.today, n, ms, outcome(reply))
    %{state | latency: Map.update!(state.latency, unit, record)}
  end

  defp outcome({:ok, _words, _client}), do: :ok
  defp outcome({:error, error, _client}), do: error

  # The day each step counts in, from the wall clock; it only moves forward,
  # so a clock set back does not log a day twice.
  defp dated(%{today: nil} = state), do: %{state | today: today(state)}

  defp dated(state) do
    today = today(state)

    if Date.after?(today, state.today) do
      log_days(state, "day ended")
      %{state | today: today}
    else
      state
    end
  end

  defp today(state), do: DateTime.to_date(state.clock.())

  defp latency(state) do
    by_unit = Map.new(state.latency, fn {unit, latency} -> {unit, Latency.summary(latency)} end)
    Status.latency(state.status, endpoint_ref(state.endpoint), by_unit)
  end

  defp log_days(%{today: nil}, _why), do: :ok

  defp log_days(state, why) do
    for %Meter{unit_id: unit} <- state.endpoint.meters,
        line = Latency.line(state.latency[unit], state.today),
        line != nil do
      Logger.info("alavi poller #{label(state)} unit #{unit}: latency, #{why}, #{line}")
    end

    :ok
  end

  defp anomalies({tag, value, client}, state) do
    {anomalies, client} = Client.take_anomalies(client)
    {{tag, value, client}, log_raw(state, &RawLog.note(&1, anomalies, now()))}
  end

  defp log_raw(state, step) do
    {lines, raw_log} = step.(state.raw_log)
    Enum.each(lines, &Logger.warning/1)
    Status.raw_lines(state.status, lines)
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
        {:ok, reconnected(%{state | client: client})}

      {:error, reason} ->
        Logger.warning(
          "alavi: cannot connect to #{endpoint.host}:#{endpoint.port}: #{inspect(reason)}"
        )

        {:error, reason, %{state | client: nil, job: Job.down(state.job, reason)}}
    end
  end

  defp reconnected(state), do: %{state | queue: Schedule.reconnected(state.queue, now())}

  defp client_opts(%Endpoint{framing: :tcp} = e),
    do: [timeout: e.timeout_ms, max_timeouts: e.max_timeouts]

  defp client_opts(%Endpoint{framing: :rtu_over_tcp} = e), do: [timeout: e.timeout_ms]

  defp reading(state, %Meter{} = meter, seen, %Register{} = reg, value) do
    %Reading{
      endpoint: endpoint_ref(state.endpoint),
      unit_id: meter.unit_id,
      meter_serial: seen.serial,
      product_code: seen.product_code,
      profile: meter.profile.name,
      profile_version: meter.profile.version,
      register_key: reg.key,
      timestamp: state.clock.(),
      value: value,
      request_id: state.job.request_id
    }
  end

  defp missed(state, %Meter{} = meter, serial, %Register{} = reg, reason, attempts) do
    %MissedRead{
      endpoint: endpoint_ref(state.endpoint),
      unit_id: meter.unit_id,
      meter_serial: serial,
      profile: meter.profile.name,
      profile_version: meter.profile.version,
      register_key: reg.key,
      timestamp: state.clock.(),
      reason: reason,
      attempts: attempts,
      raw_words: nil,
      request_id: state.job.request_id
    }
  end

  defp endpoint_ref(%Endpoint{host: host, port: port}), do: %{host: host, port: port}

  defp now, do: System.monotonic_time(:millisecond)
end
