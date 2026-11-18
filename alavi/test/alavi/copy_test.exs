defmodule Alavi.CopyTest do
  use ExUnit.Case, async: true

  import Alavi.PollerCase
  import ExUnit.CaptureLog

  alias Alavi.{Config, MeterClockRead, StoredEntry}
  alias Alavi.Copy.Progress
  alias Alavi.Selectors.Store
  alias Simulator.Meter

  @moduletag :tmp_dir
  @moduletag :capture_log

  # The collector's clock, which the tests move; the copy window is around it.
  @night ~U[2026-11-16 12:00:00Z]

  @e445 ~w(active_energy_import active_energy_export
           reactive_energy_import_while_active_import reactive_energy_export_while_active_import
           reactive_energy_import_while_active_export reactive_energy_export_while_active_export
           apparent_energy_import apparent_energy_export)

  # The 445's load-survey parameters the simulator supports (0, 1, 8, 9, 19, 23, 27).
  @survey_445 ~w(active_energy_import active_energy_export apparent_energy_import
                 apparent_energy_export voltage_average current_average frequency)

  # The 500's parameters 0-16 the profile names: all but 6 (net) and 11-16.
  @survey_500 ~w(active_energy_forwarded apparent_energy_forwarded reactive_energy_lag
                 reactive_energy_lead active_energy_import active_energy_export
                 reactive_energy_import reactive_energy_export apparent_energy_import
                 apparent_energy_export)

  defp clock! do
    agent = start_supervised!({Agent, fn -> @night end}, id: make_ref())
    {agent, fn -> Agent.get(agent, & &1) end}
  end

  defp move!(agent, at), do: Agent.update(agent, fn _ -> at end)

  defp local(utc) do
    utc
    |> DateTime.to_naive()
    |> NaiveDateTime.to_erl()
    |> :calendar.universal_time_to_local_time()
    |> NaiveDateTime.from_erl!()
  end

  # Open from ten minutes before the clock's local time to fifty after.
  defp window do
    at = local(@night)
    %{"start" => hhmm(NaiveDateTime.add(at, -600)), "end" => hhmm(NaiveDateTime.add(at, 3000))}
  end

  defp hhmm(at), do: at |> NaiveDateTime.to_time() |> Time.to_string() |> binary_part(0, 5)

  defp start!(ctx, meters, units, clock, opts \\ []) do
    {sim, port} = start_chain!(:tcp, meters)

    changes =
      Map.merge(%{"copy" => true, "interval_ms" => 60_000}, Keyword.get(opts, :endpoint, %{}))

    document = Map.put(document([endpoint(port, "tcp", units, changes)]), "copy_window", window())
    {:ok, config} = Config.parse(document, profiles())

    start_supervised!(
      {Alavi.Pollers,
       [
         config: config,
         sink: Keyword.get(opts, :sink, {Alavi.TestSink, self()}),
         clock: clock,
         raw_log: raw_log(),
         status: self(),
         selectors_dir: ctx.tmp_dir
       ]}
    )

    {sim, %{host: "127.0.0.1", port: port}}
  end

  defp meter_440(changes \\ []) do
    1
    |> Meter.new(Simulator.Profile.load!("elite_440"), %{
      "active_energy_import" => Decimal.new("123456.000")
    })
    |> Meter.stores(changes)
  end

  # What was copied until a copy ends, in order: `{:stored, entries}`,
  # `{:clock, read}` and, with `rounds`, `:round` for each meter a round read.
  # `wait_ms`: the longest silence between two events, as long as a scan takes.
  defp night!(opts \\ []) do
    opts = Keyword.validate!(opts, rounds: false, stop_after: nil, wait_ms: 30_000)
    collect([], Map.new(opts))
  end

  defp collect(acc, %{stop_after: stop_after} = opts) do
    if stop_after && Enum.count(acc, &match?({:stored, _}, &1)) >= stop_after do
      {:partial, Enum.reverse(acc)}
    else
      receive do
        {:stored, entries} -> collect([{:stored, entries} | acc], opts)
        {:meter_clock, read} -> collect([{:clock, read} | acc], opts)
        {:recorded, _events} when opts.rounds -> collect([:round | acc], opts)
        {:"$gen_cast", {:copy, _endpoint, {:finished, outcome}}} -> {outcome, Enum.reverse(acc)}
      after
        opts.wait_ms -> flunk("no copy finished")
      end
    end
  end

  defp stored(events, store),
    do: for({:stored, entries} <- events, %StoredEntry{store: ^store} = e <- entries, do: e)

  defp stamps(entries), do: entries |> Enum.map(& &1.meter_time) |> Enum.dedup()

  defp keys(entries), do: entries |> Enum.map(& &1.register_key) |> Enum.uniq() |> Enum.sort()

  defp days(entries),
    do: Enum.group_by(entries, &{NaiveDateTime.to_date(&1.meter_time), &1.register_key})

  defp today, do: Date.utc_today()

  defp midnight(date), do: NaiveDateTime.new!(date, ~T[00:00:00])

  defp copied(ctx, serial), do: Progress.load(Path.join(ctx.tmp_dir, "copied"), serial)

  describe "copy" do
    test "an Elite 440: every history and its snapshot, oldest first, then every load-survey day; " <>
           "its clock beside ours, and its selectors put back",
         ctx do
      {_agent, clock} = clock!()
      {_sim, endpoint} = start!(ctx, [meter_440()], [meter(1, "elite_440")], clock)

      {:done, events} = night!()

      history = stored(events, :history)
      assert history |> Enum.map(& &1.slot) |> Enum.dedup() == [6, 5, 4, 3, 2, 1]
      assert stamps(history) == Enum.sort(stamps(history), NaiveDateTime)
      assert Enum.all?(stamps(history), &(&1.day == 1 and &1.hour == 0 and &1.minute == 0))
      # The 445's mask: its two reactive totals are unsupported, so not sent.
      assert keys(history) == Enum.sort(@e445)
      assert length(history) == 6 * 8

      assert Enum.all?(
               history,
               &match?(
                 %StoredEntry{interval_s: nil, meter_serial: "SIM-1", profile_version: 2},
                 &1
               )
             )

      imports = for %{register_key: "active_energy_import", value: v} <- history, do: v
      assert imports == Enum.sort(imports, Decimal)

      snapshot = stored(events, :snapshot)
      assert stamps(snapshot) == [midnight(today())]
      assert keys(snapshot) == Enum.sort(@e445)

      survey = stored(events, :load_survey)
      assert keys(survey) == Enum.sort(@survey_445)
      assert Enum.all?(survey, &(&1.interval_s == 1800))
      by_day = days(survey)

      for back <- 1..6,
          key <- @survey_445,
          do: assert(length(by_day[{Date.add(today(), -back), key}]) == 48)

      # Today: only the intervals the meter's clock had ended.
      ended = div(NaiveDateTime.utc_now().hour * 60 + NaiveDateTime.utc_now().minute, 30)
      assert length(Map.get(by_day, {today(), "voltage_average"}, [])) in (ended - 1)..ended

      assert Enum.all?(
               survey,
               &(&1.register_key != "voltage_average" or Decimal.equal?(&1.value, 240))
             )

      # Once with the first round's names, then at the visit's start and end.
      assert [_daily, _start, _end] = clocks = for({:clock, read} <- events, do: read)
      assert Enum.all?(clocks, &match?(%MeterClockRead{unit_id: 1, meter_serial: "SIM-1"}, &1))

      assert copied(ctx, "SIM-1") ==
               {:ok,
                %{
                  history: List.last(stamps(history)),
                  snapshot: midnight(today()),
                  load_survey: midnight(Date.add(today(), -1))
                }}

      assert Store.owed(ctx.tmp_dir, endpoint) == :none

      assert {:ok,
              %{{1, "elite_440", :history} => 0, {1, "elite_440", :load_survey_day} => 0} = left} =
               Store.left(ctx.tmp_dir, endpoint)

      assert left[{1, "elite_440", :snapshot}] == 0
      assert left[{1, "elite_440", :load_survey_parameter}] == 0
      assert_received {:"$gen_cast", {:copy, ^endpoint, {:at, 1, :load_survey, :copying, 49, 49}}}
    end

    test "an Elite 500: histories, snapshots and each load-survey parameter after its settle",
         ctx do
      {_agent, clock} = clock!()
      base = Map.new(@survey_500, &{&1, Decimal.new(100_000)})

      meter =
        3
        |> Meter.new(Simulator.Profile.load!("elite_500"), %{
          "active_energy_import" => Decimal.new("1234.5")
        })
        |> Meter.stores(days: 2, snapshots: 3, base: base)

      {_sim, endpoint} = start!(ctx, [meter], [meter(3, "elite_500")], clock)

      {:done, events} = night!()

      history = stored(events, :history)
      assert length(stamps(history)) == 6
      assert length(history) == 6 * 16

      snapshot = stored(events, :snapshot)
      assert stamps(snapshot) == Enum.map(-2..0, &midnight(Date.add(today(), &1)))
      assert length(snapshot) == 3 * 16

      survey = stored(events, :load_survey)
      assert keys(survey) == Enum.sort(@survey_500)
      by_day = days(survey)
      yesterday = Date.add(today(), -1)

      # Each parameter rises at its own rate, the same every interval: a value
      # read before the meter showed the new parameter would be another's.
      per_key =
        for key <- @survey_500 do
          intervals = by_day[{yesterday, key}]
          assert length(intervals) == 96

          assert [value] =
                   intervals |> Enum.map(&Decimal.to_string(&1.value, :normal)) |> Enum.uniq()

          value
        end

      assert length(Enum.uniq(per_key)) == length(@survey_500)

      assert [_daily, _start, _end] =
               for({:clock, %MeterClockRead{unit_id: 3}} <- events, do: :read)

      assert Store.owed(ctx.tmp_dir, endpoint) == :none
      assert {:ok, %{load_survey: _, history: _, snapshot: _}} = copied(ctx, "SIM-3")
    end

    test "an Elite 500 counting more load-survey days than its day register reaches copies " <>
           "from the oldest it reaches, day 255",
         ctx do
      {_agent, clock} = clock!()

      meter =
        3
        |> Meter.new(Simulator.Profile.load!("elite_500"), %{})
        |> Meter.stores(days: 300, snapshots: 1)

      start!(ctx, [meter], [meter(3, "elite_500")], clock)

      assert {:partial, events} = night!(stop_after: 8, wait_ms: 60_000)
      assert [first | _] = stored(events, :load_survey)
      assert NaiveDateTime.to_date(first.meter_time) == Date.add(today(), -255)
    end

    test "a window that closes mid-copy stops it at an entry boundary, session closed, " <>
           "and the next night resumes where it stopped, polls going on between entries",
         ctx do
      {agent, clock} = clock!()

      {sim, endpoint} =
        start!(ctx, [meter_440()], [meter(1, "elite_440")], clock,
          endpoint: %{"interval_ms" => 50}
        )

      Simulator.faults(sim, delay_ms: 5)

      {:partial, first} = night!(rounds: true, stop_after: 12)
      move!(agent, DateTime.add(@night, 3600))
      {:window, rest} = night!(rounds: true)
      first = first ++ rest

      assert Store.owed(ctx.tmp_dir, endpoint) == :none
      assert {:ok, progress} = copied(ctx, "SIM-1")
      refute progress[:load_survey] == midnight(Date.add(today(), -1))

      copies = Enum.filter(first, &match?({:stored, _}, &1))
      between = first |> Enum.drop_while(&(&1 == :round)) |> Enum.take(length(first) - 1)
      assert :round in Enum.drop(between, -1), "no poll round ran between the copy's entries"
      assert length(copies) < 6 + 1 + 49

      move!(agent, DateTime.add(@night, 86_400))
      {:done, second} = night!()

      assert stored(second, :history) == []
      assert stored(second, :snapshot) == []

      # Each history once over both nights; a load-survey interval twice only
      # in the day the window closed on, or today, copied again each night.
      all_history = stored(first, :history) ++ stored(second, :history)
      assert length(all_history) == 6 * 8
      assert length(Enum.uniq_by(all_history, &{&1.meter_time, &1.register_key})) == 6 * 8

      survey = stored(first, :load_survey) ++ stored(second, :load_survey)

      twice =
        survey
        |> Enum.frequencies_by(&{&1.meter_time, &1.register_key})
        |> Enum.filter(&(elem(&1, 1) > 1))

      again =
        twice |> Enum.map(fn {{at, _key}, _n} -> NaiveDateTime.to_date(at) end) |> Enum.uniq()

      assert length(again) <= 2

      first_days = Enum.map(stored(first, :load_survey), &NaiveDateTime.to_date(&1.meter_time))
      assert Enum.all?(again, &(&1 == today() or &1 in first_days))

      for back <- 1..6, key <- @survey_445 do
        intervals =
          survey
          |> Enum.filter(
            &(&1.register_key == key and
                NaiveDateTime.to_date(&1.meter_time) == Date.add(today(), -back))
          )

        assert length(Enum.uniq_by(intervals, & &1.meter_time)) == 48
      end

      assert {:ok, %{load_survey: last}} = copied(ctx, "SIM-1")
      assert last == midnight(Date.add(today(), -1))
    end

    test "a connection dropped mid-copy leaves the restore owed, done on reconnect; " <>
           "what was copied stays copied, and the next night copies the rest",
         ctx do
      {agent, clock} = clock!()

      {sim, endpoint} =
        start!(ctx, [meter_440()], [meter(1, "elite_440")], clock,
          endpoint: %{"interval_ms" => 200}
        )

      # The first read of a load-survey day's values.
      Simulator.faults(sim, dropped_requests: [{1, 807}])

      log =
        capture_log(fn ->
          {:fault, first} = night!()
          assert length(stored(first, :history)) == 6 * 8
          assert stored(first, :load_survey) == []

          assert_receive {:"$gen_cast", {:selectors, ^endpoint, {:owed, "left by a copy", 0}}},
                         2_000

          assert_receive {:"$gen_cast", {:selectors, ^endpoint, :restored}}, 5_000
        end)

      assert log =~ "connection_lost" or log =~ ":closed"
      assert Store.owed(ctx.tmp_dir, endpoint) == :none
      assert {:ok, %{load_survey_day: 0, load_survey_parameter: 0}} = left(ctx, endpoint)
      assert {:ok, progress} = copied(ctx, "SIM-1")
      assert Map.keys(progress) |> Enum.sort() == [:history, :snapshot]

      Simulator.clear_faults(sim)
      move!(agent, DateTime.add(@night, 86_400))
      {:done, second} = night!()
      assert stored(second, :history) == []
      assert stored(second, :snapshot) == []
      assert keys(stored(second, :load_survey)) == Enum.sort(@survey_445)
    end

    for {key, read} <- [{"logger_type", 3}, {"energy_storage_type", 1}] do
      test "an Elite 500 whose #{key} reads #{read}, not its profile's value, " <>
             "has no load survey copied; its histories and snapshots are",
           ctx do
        {_agent, clock} = clock!()

        meter =
          3
          |> Meter.new(Simulator.Profile.load!("elite_500"), %{
            "active_energy_import" => Decimal.new("1234.5")
          })
          |> Meter.stores(days: 2, snapshots: 3, settings: %{unquote(key) => unquote(read)})

        {_sim, endpoint} = start!(ctx, [meter], [meter(3, "elite_500")], clock)

        {:done, events} = night!()
        assert stored(events, :load_survey) == []
        assert length(stamps(stored(events, :history))) == 6
        assert length(stamps(stored(events, :snapshot))) == 3

        assert_received {:"$gen_cast", {:copy, ^endpoint, {:error, 3, detail}}}
        assert detail =~ "load_survey" and detail =~ unquote(key)
        assert Store.owed(ctx.tmp_dir, endpoint) == :none
        assert {:ok, progress} = copied(ctx, "SIM-3")
        refute Map.has_key?(progress, :load_survey)
      end
    end

    test "a selector write the meter refuses skips that store, its session closed; the rest is copied",
         ctx do
      {_agent, clock} = clock!()
      {sim, endpoint} = start!(ctx, [meter_440()], [meter(1, "elite_440")], clock)
      Simulator.faults(sim, refused_writes: %{{1, 520} => 4})

      capture_log(fn ->
        {:done, events} = night!()
        assert stored(events, :history) == []
        assert length(stored(events, :snapshot)) == 8
        assert keys(stored(events, :load_survey)) == Enum.sort(@survey_445)
      end)

      assert_received {:"$gen_cast", {:copy, ^endpoint, {:error, 1, detail}}}
      assert detail =~ "history" and detail =~ "exception, 4"
      assert Store.owed(ctx.tmp_dir, endpoint) == :none
      assert {:ok, progress} = copied(ctx, "SIM-1")
      refute Map.has_key?(progress, :history)
    end

    test "a crash after an entry is kept and before its progress is saved copies that entry again, " <>
           "once, and nothing else twice",
         ctx do
      {_agent, clock} = clock!()
      counter = :counters.new(1, [])
      sink = {Alavi.CrashingSink, {self(), counter, 3}}

      {_sim, endpoint} = start!(ctx, [meter_440()], [meter(1, "elite_440")], clock, sink: sink)

      {:done, events} =
        capture_log(fn -> send(self(), {:night, night!()}) end)
        |> then(fn log ->
          assert log =~ "crashed after entry 3 was kept"
          assert_received {:night, night}
          night
        end)

      history = stored(events, :history)

      twice =
        history
        |> Enum.frequencies_by(&{&1.meter_time, &1.register_key})
        |> Enum.filter(&(elem(&1, 1) > 1))

      # The third history copied, slot 4, is the one copied again.
      [{third, _} | _] =
        for {:stored, [%StoredEntry{store: :history, slot: 4} = e | _]} <- events,
            do: {e.meter_time, e}

      assert Enum.map(twice, fn {{at, _key}, 2} -> at end) |> Enum.uniq() == [third]
      assert length(twice) == 8

      for {{at, key}, 2} <- twice do
        [a, b] = Enum.filter(history, &(&1.meter_time == at and &1.register_key == key))
        assert Decimal.equal?(a.value, b.value)
      end

      assert length(Enum.uniq_by(history, &{&1.meter_time, &1.register_key})) == 6 * 8
      assert Store.owed(ctx.tmp_dir, endpoint) == :none
    end
  end

  defp left(ctx, endpoint) do
    {:ok, left} = Store.left(ctx.tmp_dir, endpoint)
    {:ok, Map.new(left, fn {{_unit, _model, name}, value} -> {name, value} end)}
  end
end
