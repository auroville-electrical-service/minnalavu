defmodule Alavi.Copy.Copier do
  @moduledoc """
  Runs one phase of an `Alavi.Copy.Run` on the poller's held connection: the
  shell around `Alavi.Copy.Stores` and `Alavi.Decode.Stored`. Every write is
  `Alavi.Selectors.Session.set/5`, inside a session opened per meter and
  store; every read is a profile-named run of registers.

  An entry's stored entries are recorded to the sink before its progress is
  saved (`Alavi.Copy.Progress`), so a crash between the two copies it again,
  once, and the store keeps the second as a duplicate. A failure on one
  store closes its session and the visit goes on to the meter's next store;
  one the sink or the progress file refuses ends the meter's visit. A session whose connection was lost, or that would not close,
  leaves its restore owed, to the poller (`io.owe_restore`), and ends the
  run: the endpoint is faulted until the restore is done, and no copy starts.

  A fill's pass (`Alavi.Copy.Fill`) scans its store back to the range's
  start, copies the entries in the range with the request's ID, and never
  moves the progress; once its entries are recorded, its
  `Alavi.FillResult` is. A pass that fails sends no result, and the fill
  tries it again the next night.

  A NaN or infinity where the meter's mask supports the quantity (or the
  profile has no mask) is not sent, and not a missed read, which is a live
  register's: it is logged with the entry it was in, and counted on the
  status page.
  """

  require Logger

  alias Alavi.Config.Meter
  alias Alavi.Copy.{Fill, Progress, Run, Stores}
  alias Alavi.Decode.Stored, as: Decode
  alias Alavi.{FillResult, MeterClockRead, Sink, Status, StoredEntry}
  alias Alavi.Modbus.{Client, Selector}
  alias Alavi.Profile.{Identity, Stored}
  alias Alavi.Selectors.Session

  @typedoc """
  What the poller lends the copy: its identity read (`identify`), a read on
  the held connection that never reconnects (`read`), a call on its client
  that logs the client's anomalies (`client`), and putting a restore owed in
  its queue (`owe_restore`). `state` is the poller's, with at least the keys
  this module reads.
  """
  @type io :: %{
          identify: (Meter.t(), state() ->
                       {{:ok, Identity.observed()} | {:missed, term(), non_neg_integer(), term()},
                        state()}),
          read: (state(), read() -> {{:ok, [0..0xFFFF]} | {:error, term()}, state()}),
          client: (state(), (Client.t() -> {term(), Client.t()}) -> {term(), state()}),
          owe_restore: (state() -> state())
        }
  @type state :: %{
          :endpoint => %{host: String.t(), port: :inet.port_number()},
          :client => Client.t() | nil,
          :connections => non_neg_integer(),
          :sink => Sink.t(),
          :status => GenServer.server(),
          :clock => (-> DateTime.t()),
          :selectors_dir => Path.t(),
          :copies_dir => Path.t(),
          optional(atom()) => term()
        }
  @type read :: {1..247, :holding, 0..0xFFFF, 1..125}

  # contract: test/alavi/copy_test.exs "copy"
  @spec step(Run.t(), state(), io()) :: {Run.t(), state()}
  def step(%Run{phase: {:visit, meter}} = run, state, io), do: visit(run, meter, state, io)
  def step(%Run{phase: {:open, visit}} = run, state, io), do: open(run, visit, state, io)

  def step(%Run{phase: {:scan, visit, scope}} = run, state, io),
    do: held(run, visit, scope, state, io, &scan/5)

  def step(%Run{phase: {:copy, visit, scope}} = run, state, io),
    do: held(run, visit, scope, state, io, &copy/5)

  def step(%Run{phase: {:close, visit, scope}} = run, state, io),
    do: close(run, visit, scope, state, io)

  def step(%Run{phase: {:end_visit, visit}} = run, state, io),
    do: end_visit(run, visit, state, io)

  # contract: test/alavi/copy_test.exs "copy"
  # contract: test/alavi/poller/firmware_test.exs "start_link/1"
  @doc """
  Read `meter`'s clock and record it, under the serial it reported: for a
  copy visit, and for the daily read riding the names. A profile with no
  `meter_clock` reads nothing.
  """
  @spec meter_clock(Meter.t(), String.t(), state(), (state(), read() -> {term(), state()})) ::
          {{:ok, [0..0xFFFF]} | {:error, term()}, state()}
  def meter_clock(%Meter{profile: %{meter_clock: nil}}, _serial, state, _read),
    do: {{:error, :no_meter_clock}, state}

  def meter_clock(%Meter{profile: profile} = meter, serial, state, read) do
    case read.(state, {meter.unit_id, :holding, profile.meter_clock.address, 2}) do
      {{:ok, words}, state} ->
        record_clock(meter, serial, words, state)
        {{:ok, words}, state}

      {{:error, _} = error, state} ->
        {error, state}
    end
  end

  defp record_clock(meter, serial, words, state) do
    case Decode.stamp(meter.profile.meter_clock, words) do
      {:ok, at} ->
        read = %MeterClockRead{
          endpoint: endpoint(state),
          unit_id: meter.unit_id,
          meter_serial: serial,
          profile: meter.profile.name,
          profile_version: meter.profile.version,
          meter_time: at,
          collector_at: state.clock.()
        }

        Sink.record(state.sink, [read])

      {:error, why} ->
        warn(state, meter, "meter clock not decoded: #{inspect(why)}")
    end
  end

  defp visit(run, %Meter{profile: %{stored: nil}} = meter, state, _io),
    do: {Run.next_meter(run), failed(state, meter, "its profile has no stored section")}

  defp visit(run, meter, state, io) do
    case io.identify.(meter, state) do
      {{:ok, seen}, state} ->
        visited(run, meter, seen, state, io)

      {{:missed, {:unreachable, _} = reason, _n, _serial}, state} ->
        {Run.unreached(run, meter), unreached(state, meter, reason)}

      {{:missed, reason, _n, _serial}, state} ->
        {Run.next_meter(run), failed(state, meter, {:identity, reason})}
    end
  end

  defp visited(run, meter, seen, state, io) do
    with {:ok, progress} <- Progress.load(state.copies_dir, seen.serial),
         {{:ok, clock}, state} <- meter_clock(meter, seen.serial, state, io.read) do
      visit = %{
        meter: meter,
        serial: seen.serial,
        product_code: seen.product_code,
        progress: progress,
        clock: clock,
        stores: Run.passes(run, seen.serial)
      }

      {%{run | phase: {:open, visit}}, state}
    else
      {:error, unreadable} -> {Run.next_meter(run), failed(state, meter, {:progress, unreadable})}
      {{:error, why}, state} -> {Run.next_meter(run), failed(state, meter, {:meter_clock, why})}
    end
  end

  defp open(run, %{stores: []} = visit, state, _io),
    do: {%{run | phase: {:end_visit, visit}}, state}

  defp open(run, %{stores: [{store, pass} | rest]} = visit, state, io) do
    visit = %{visit | stores: rest}

    case counts(visit.meter, store, state, io) do
      {{:ok, %{available: 0}}, state} ->
        held_none(run, visit, store, pass, state)

      {{:ok, %{parameters: []}}, state} ->
        held_none(run, visit, store, pass, state)

      {{:ok, counts}, state} ->
        session(run, visit, {store, pass}, counts, state, io)

      {{:error, why}, state} ->
        {%{run | phase: {:open, visit}}, failed(state, visit.meter, {store, why})}
    end
  end

  # A store the meter holds nothing of: a fill's pass is finished, with all of its range gone.
  defp held_none(run, visit, _store, :nightly, state), do: {%{run | phase: {:open, visit}}, state}

  defp held_none(run, visit, store, %Fill{} = fill, state) do
    scope = %{store: store, pass: fill, ended: :exhausted, found: []}
    {run, state} = fill_result(run, visit, scope, state)
    {%{run | phase: {:open, visit}}, state}
  end

  defp counts(meter, :load_survey, state, io) do
    survey = meter.profile.stored.load_survey

    with {:ok, state} <- required(meter.unit_id, survey.requires, state, io),
         {{:ok, [available]}, state} <-
           io.read.(state, {meter.unit_id, :holding, survey.available, 1}),
         {{:ok, interval}, state} <-
           io.read.(state, {meter.unit_id, :holding, survey.interval, 1}),
         {{:ok, words}, state} <-
           io.read.(
             state,
             {meter.unit_id, :holding, survey.mask.address, Stores.mask_words(survey.mask.type)}
           ) do
      {:ok, mask} = Decode.mask(survey.mask, words)

      case Decode.interval(interval) do
        {:ok, _minutes} ->
          counts = %{
            available: Selector.reachable(meter.profile.name, :load_survey_day, available),
            mask: mask,
            interval: interval,
            parameters: Stores.parameters(survey, mask)
          }

          {{:ok, counts}, state}

        {:error, why} ->
          {{:error, {:interval, interval, why}}, state}
      end
    end
  end

  defp counts(meter, store, state, io) do
    block = Stored.section(meter.profile.stored, store)

    case io.read.(state, {meter.unit_id, :holding, block.available, 1}) do
      {{:ok, [available]}, state} ->
        {{:ok, %{available: available, mask: nil, interval: nil, parameters: nil}}, state}

      error ->
        error
    end
  end

  # Before anything of the survey is read: a register reading other than its
  # profile requires means the selectors show some other survey, or one kept
  # another way, so the store is not copied (read-only: never set back).
  defp required(unit, requires, state, io) do
    Enum.reduce_while(requires, {:ok, state}, fn %{key: key, address: address, value: want},
                                                 {:ok, state} ->
      case io.read.(state, {unit, :holding, address, 1}) do
        {{:ok, [^want]}, state} -> {:cont, {:ok, state}}
        {{:ok, [read]}, state} -> {:halt, {{:error, {:requires, key, read, want}}, state}}
        error -> {:halt, error}
      end
    end)
  end

  defp session(run, visit, {store, pass}, counts, state, io) do
    meter = visit.meter

    {result, state} =
      io.client.(state, fn client ->
        case Session.open(
               client,
               state.selectors_dir,
               endpoint(state),
               meter.unit_id,
               meter.profile.name,
               selectors(store, counts)
             ) do
          {:ok, session, client} -> {{:ok, session}, client}
          {:error, reason, client} -> {{:error, reason}, client}
        end
      end)

    case result do
      {:ok, session} ->
        scope =
          Map.merge(counts, %{
            store: store,
            pass: pass,
            ended: nil,
            session: session,
            connection: state.connections,
            slots: Stores.slots(store, counts.available),
            found: [],
            due: [],
            done: 0,
            of: 0,
            day: nil,
            rescans: 0
          })

        {%{run | phase: {:scan, visit, scope}}, at(state, visit, scope)}

      # The restore a cut visit left is still to do: no session opens tonight.
      {:error, :restore_owed} ->
        {Run.faulted(run), failed(state, meter, {store, {:session, :restore_owed}})}

      {:error, reason} ->
        {%{run | phase: {:open, visit}}, failed(state, meter, {store, {:session, reason}})}
    end
  end

  defp selectors(:load_survey, counts),
    do: [load_survey_day: counts.available, load_survey_parameter: counts.mask]

  defp selectors(store, counts), do: [{store, counts.available}]

  # The connection a session was opened on must be the one each of its steps runs on.
  defp held(run, visit, scope, state, io, step) do
    if connected?(state, scope),
      do: step.(run, visit, scope, state, io),
      else: lost(run, visit, state, io, :connection_lost)
  end

  defp connected?(%{client: %Client{socket: socket}, connections: n}, %{connection: n}),
    do: socket != nil

  defp connected?(_state, _scope), do: false

  defp lost(run, visit, state, io, why) do
    state = failed(state, visit.meter, {visit_store(run), why})
    {Run.cut(run), io.owe_restore.(state)}
  end

  defp visit_store(%Run{phase: {_phase, _visit, scope}}), do: scope.store
  defp visit_store(_run), do: :none

  defp scan(run, visit, %{slots: []} = scope, state, _io), do: scanned(run, visit, scope, state)

  defp scan(run, visit, %{slots: [slot | rest]} = scope, state, io) do
    stamp = stamp_entry(visit.meter, scope.store)

    with {:ok, state} <- set(state, io, scope, slot_selector(scope.store), slot, scope.available),
         {:ok, words, state} <- read(state, io, {visit.meter.unit_id, :holding, stamp.address, 2}),
         {:ok, at, state} <- decoded(Decode.stamp(stamp, words), state) do
      scope = %{scope | slots: rest, day: day(scope, slot)}

      case scanned_to(scope.pass, scope, slot, at, visit) do
        {:more, found} when rest != [] ->
          {%{run | phase: {:scan, visit, %{scope | found: found}}}, state}

        {:more, found} ->
          scanned(run, visit, %{scope | found: found, slots: [], ended: :exhausted}, state)

        {:found, found} ->
          scanned(run, visit, %{scope | found: found, slots: [], ended: :older}, state)
      end
    else
      {:error, why, state} -> broke(run, visit, scope, state, io, why)
    end
  end

  defp scanned_to(:nightly, scope, slot, at, visit),
    do: Stores.scanned(scope.found, slot, at, visit.progress[scope.store])

  defp scanned_to(%Fill{from: from}, scope, slot, at, _visit),
    do: Stores.fill_scanned(scope.found, slot, at, scope.store, from)

  defp scanned(run, visit, %{slots: []} = scope, state) when scope.ended == nil,
    do: scanned(run, visit, %{scope | ended: :exhausted}, state)

  defp scanned(run, visit, scope, state) do
    due = Stores.due(in_range(scope.pass, scope.found), scope.parameters)
    scope = %{scope | due: due, of: length(due), done: 0}
    state = at(state, visit, scope)

    if due == [],
      do: finished(run, visit, scope, state),
      else: {%{run | phase: {:copy, visit, scope}}, state}
  end

  defp in_range(:nightly, found), do: found
  defp in_range(%Fill{to: to}, found), do: Stores.before(found, to)

  # Every entry due is recorded: a fill's result next, then the session closed.
  defp finished(run, visit, scope, state) do
    {run, state} = fill_result(run, visit, scope, state)
    {%{run | phase: {:close, visit, scope}}, state}
  end

  defp fill_result(run, _visit, %{pass: :nightly}, state), do: {run, state}

  defp fill_result(run, visit, %{pass: %Fill{} = fill} = scope, state) do
    result = %FillResult{
      request_id: fill.id,
      endpoint: endpoint(state),
      unit_id: visit.meter.unit_id,
      meter_serial: visit.serial,
      store: scope.store,
      gone_before: Stores.gone_before(scope.ended, scope.found, fill.from, fill.to),
      finished_at: state.clock.()
    }

    case record(state, [result]) do
      :ok -> {Run.filled(run, fill.id, visit.serial, scope.store), state}
      {:error, why} -> {run, failed(state, visit.meter, {scope.store, {:fill, fill.id, why}})}
    end
  end

  defp copy(run, visit, %{store: :load_survey} = scope, state, io),
    do: copy_day(run, visit, scope, state, io)

  defp copy(run, visit, %{due: [{slot, stamp} | rest]} = scope, state, io) do
    block = Stored.section(visit.meter.profile.stored, scope.store)
    runs = Stores.runs(Stores.block_spans(block))

    with {:ok, state} <- set(state, io, scope, block.selector, slot, scope.available),
         {:ok, words, state} <- read_runs(state, io, visit.meter.unit_id, runs),
         {:ok, decoded, state} <- decoded(decode_block(block, words), state),
         {:ok, state} <- same(decoded.meter_time, stamp, state) do
      copied_at = state.clock.()
      not_finite(state, visit, scope.store, stamp, decoded.not_finite)

      entries =
        for {key, value} <- decoded.entries,
            do: entry(state, visit, scope, {stamp, nil}, key, value, slot, copied_at)

      kept(run, visit, %{scope | due: rest}, stamp, entries, state)
    else
      {:error, why, state} -> broke(run, visit, scope, state, io, why)
    end
  end

  defp copy_day(run, visit, %{due: [{slot, stamp, parameter, last} | rest]} = scope, state, io) do
    survey = visit.meter.profile.stored.load_survey
    unit = visit.meter.unit_id
    {:ok, minutes} = Decode.interval(scope.interval)

    with {:ok, state, scope} <- select_day(state, io, scope, slot),
         {:ok, state} <-
           set(state, io, scope, :load_survey_parameter, parameter.number, scope.mask),
         {:ok, stamp_words, state} <- read(state, io, {unit, :holding, survey.stamp.address, 2}),
         {:ok, ended, state} <- decoded(ended(survey, stamp_words, minutes, visit), state),
         {:ok, values, state} <- read_runs(state, io, unit, Stores.value_runs(survey, ended)),
         read = %{
           stamp: stamp_words,
           interval: scope.interval,
           values: values_of(values, survey, ended),
           clock: {visit.meter.profile.meter_clock, visit.clock}
         },
         {:ok, day, state} <- decoded(Decode.day(survey, read), state),
         {:ok, state} <- same(day.meter_time, stamp, state) do
      copied_at = state.clock.()
      times = Enum.map(day.not_finite, &NaiveDateTime.to_iso8601/1)
      not_finite(state, visit, {:load_survey, parameter.key}, stamp, times)

      entries =
        for {start, value} <- day.entries,
            do:
              entry(
                state,
                visit,
                scope,
                {start, day.interval_s},
                parameter.key,
                value,
                slot,
                copied_at
              )

      progress = if last and day.not_ended == 0, do: stamp
      kept(run, visit, %{scope | due: rest}, progress, entries, state)
    else
      {:error, why, state} -> broke(run, visit, scope, state, io, why)
    end
  end

  defp ended(survey, stamp_words, minutes, visit) do
    with {:ok, at} <- Decode.stamp(survey.stamp, stamp_words),
         {:ok, clock} <- Decode.stamp(visit.meter.profile.meter_clock, visit.clock),
         do: {:ok, Decode.ended(at, minutes, clock)}
  end

  defp values_of(by_address, %{values: %{address: address}}, ended),
    do: Stores.words(by_address, address, 2 * ended)

  defp select_day(state, _io, %{day: slot} = scope, slot), do: {:ok, state, scope}

  defp select_day(state, io, scope, slot) do
    case set(state, io, scope, :load_survey_day, slot, scope.available) do
      {:ok, state} -> {:ok, state, %{scope | day: slot}}
      {:error, _why, _state} = failure -> failure
    end
  end

  # The entry's events recorded, then its progress saved: never the other way round.
  defp kept(run, visit, scope, progress, entries, state) do
    with :ok <- record(state, entries),
         {:ok, visit} <- advanced(visit, scope.store, nightly(scope.pass, progress), state) do
      scope = %{scope | done: scope.done + 1}
      state = at(state, visit, scope)

      if scope.due == [],
        do: finished(run, visit, scope, state),
        else: {%{run | phase: {:copy, visit, scope}}, state}
    else
      {:error, why} ->
        {%{run | phase: {:close, %{visit | stores: []}, scope}},
         failed(state, visit.meter, {scope.store, why})}
    end
  end

  # A fill never moves the nightly mark.
  defp nightly(:nightly, progress), do: progress
  defp nightly(%Fill{}, _progress), do: nil

  defp record(_state, []), do: :ok

  defp record(state, entries) do
    case Sink.record(state.sink, entries) do
      :ok -> :ok
      {:error, reason} -> {:error, {:sink, reason}}
    end
  end

  defp advanced(visit, _store, nil, _state), do: {:ok, visit}

  defp advanced(visit, store, stamp, state) do
    progress = Map.put(visit.progress, store, stamp)

    case Progress.save(state.copies_dir, visit.serial, progress) do
      :ok -> {:ok, %{visit | progress: progress}}
      {:error, reason} -> {:error, {:progress, reason}}
    end
  end

  # A stamp not where the scan found it: the meter has stored a new entry
  # since, shifting the slots. Scanned again, once; a second shift fails the meter.
  defp broke(run, visit, %{rescans: 0} = scope, state, _io, {:shifted, _expected, _found}) do
    scope = %{
      scope
      | slots: Stores.slots(scope.store, scope.available),
        found: [],
        due: [],
        of: 0,
        ended: nil,
        rescans: 1
    }

    {%{run | phase: {:scan, visit, scope}}, state}
  end

  defp broke(run, visit, scope, state, io, why) do
    if connected?(state, scope),
      do:
        {%{run | phase: {:close, visit, scope}}, failed(state, visit.meter, {scope.store, why})},
      else: lost(%{run | phase: {:copy, visit, scope}}, visit, state, io, why)
  end

  defp read(state, io, request) do
    case io.read.(state, request) do
      {{:ok, words}, state} -> {:ok, words, state}
      {{:error, why}, state} -> {:error, {:read, request, why}, state}
    end
  end

  defp decoded({:ok, value}, state), do: {:ok, value, state}
  defp decoded({:error, why}, state), do: {:error, {:decode, why}, state}

  defp same(found, expected, state) do
    if NaiveDateTime.compare(found, expected) == :eq,
      do: {:ok, state},
      else: {:error, {:shifted, expected, found}, state}
  end

  defp close(run, visit, scope, state, io) do
    {result, state} =
      if connected?(state, scope),
        do: io.client.(state, &closed(Session.close(scope.session, &1))),
        else: {{:error, :connection_lost}, state}

    case result do
      :ok ->
        {%{run | phase: {:open, visit}}, state}

      {:error, why} ->
        lost(%{run | phase: {:close, visit, scope}}, visit, state, io, {:close, why})
    end
  end

  defp closed({:ok, :restored, client}), do: {:ok, client}
  defp closed({:error, reason, client}), do: {{:error, reason}, client}

  defp end_visit(run, visit, state, io) do
    case meter_clock(visit.meter, visit.serial, state, io.read) do
      {{:ok, _words}, state} ->
        {Run.next_meter(run), state}

      {{:error, why}, state} ->
        {Run.next_meter(run),
         warned(state, visit.meter, "meter clock not read at the visit's end: #{inspect(why)}")}
    end
  end

  defp set(state, io, scope, name, value, bound) do
    {result, state} =
      io.client.(state, fn client ->
        case Session.set(scope.session, client, name, value, bound) do
          {:ok, client} -> {:ok, client}
          {:error, reason, client} -> {{:error, {:selector, name, value, reason}}, client}
        end
      end)

    case result do
      :ok -> {:ok, state}
      {:error, why} -> {:error, why, state}
    end
  end

  defp read_runs(state, io, unit, runs) do
    Enum.reduce_while(runs, {:ok, [], state}, fn {address, count} = run, {:ok, acc, state} ->
      case read(state, io, {unit, :holding, address, count}) do
        {:ok, words, state} -> {:cont, {:ok, [{run, words} | acc], state}}
        {:error, _why, _state} = failure -> {:halt, failure}
      end
    end)
    |> then(fn
      {:ok, read, state} -> {:ok, Stores.at(read), state}
      failure -> failure
    end)
  end

  defp decode_block(block, by_address) do
    words = &Stores.words(by_address, &1, &2)
    registers = Map.new(block.registers, &{&1.key, words.(&1.address, 2)})
    mask = block.mask && words.(block.mask.address, Stores.mask_words(block.mask.type))
    Decode.block(block, words.(block.stamp.address, 2), mask, registers)
  end

  defp entry(state, visit, scope, {meter_time, interval_s}, key, value, slot, copied_at) do
    %StoredEntry{
      endpoint: endpoint(state),
      unit_id: visit.meter.unit_id,
      meter_serial: visit.serial,
      product_code: visit.product_code,
      profile: visit.meter.profile.name,
      profile_version: visit.meter.profile.version,
      store: scope.store,
      meter_time: meter_time,
      interval_s: interval_s,
      register_key: key,
      value: value,
      slot: slot,
      copied_at: copied_at,
      request_id: request_id(scope.pass)
    }
  end

  defp request_id(:nightly), do: nil
  defp request_id(%Fill{id: id}), do: id

  defp not_finite(_state, _visit, _what, _stamp, []), do: :ok

  defp not_finite(state, visit, what, stamp, which) do
    warn(
      state,
      visit.meter,
      "#{label(what)} #{NaiveDateTime.to_iso8601(stamp)}: #{length(which)} not finite, not sent: #{Enum.join(which, ", ")}"
    )

    Status.copy(state.status, endpoint(state), {:not_finite, length(which)})
  end

  defp label({store, key}), do: "#{store} #{key}"
  defp label(store), do: "#{store}"

  defp stamp_entry(meter, :load_survey), do: meter.profile.stored.load_survey.stamp
  defp stamp_entry(meter, store), do: Stored.section(meter.profile.stored, store).stamp

  defp slot_selector(:load_survey), do: :load_survey_day
  defp slot_selector(store), do: store

  defp day(%{store: :load_survey}, slot), do: slot
  defp day(_scope, _slot), do: nil

  defp at(state, visit, %{
         store: store,
         done: done,
         of: of,
         slots: slots,
         found: found,
         available: available
       }) do
    {phase, n, m} =
      if of == 0 and slots != [],
        do: {:scanning, length(found) + 1, available},
        else: {:copying, done, of}

    Status.copy(state.status, endpoint(state), {:at, visit.meter.unit_id, store, phase, n, m})
    state
  end

  defp failed(state, meter, why) do
    Status.copy(state.status, endpoint(state), {:error, meter.unit_id, inspect(why)})
    warned(state, meter, "not copied tonight: #{inspect(why)}")
  end

  defp unreached(state, meter, why) do
    Status.copy(state.status, endpoint(state), {:error, meter.unit_id, inspect(why)})

    warned(
      state,
      meter,
      "endpoint not reached, copied again in #{meter.retry_ms} ms: #{inspect(why)}"
    )
  end

  defp warned(state, meter, message) do
    warn(state, meter, message)
    state
  end

  defp warn(%{endpoint: %{host: host, port: port}}, meter, message),
    do: Logger.warning("alavi copy #{host}:#{port} unit #{meter.unit_id}: #{message}")

  defp endpoint(%{endpoint: %{host: host, port: port}}), do: %{host: host, port: port}
end
