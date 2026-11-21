defmodule Alavi.Copy.StoresTest do
  use ExUnit.Case, async: true

  alias Alavi.Copy.Stores

  setup_all do
    {:ok, profiles} =
      Alavi.Profile.load_dir(Path.expand("../../../../contract/profiles", __DIR__))

    %{p440: profiles["elite_440"], p500: profiles["elite_500"]}
  end

  describe "slots/2" do
    test "histories from 1, since 0 shows live values; snapshots and days from 0, today" do
      assert Stores.slots(:history, 6) == [1, 2, 3, 4, 5, 6]
      assert Stores.slots(:snapshot, 1) == [0]
      assert Stores.slots(:load_survey, 3) == [0, 1, 2]
      assert Stores.slots(:history, 0) == []
      assert Stores.slots(:snapshot, 0) == []
    end
  end

  describe "scanned/4" do
    test "goes on while each stamp is newer than the last copied, and stops at the first that is not" do
      last = ~N[2026-10-01 00:00:00]

      assert {:more, [{1, ~N[2026-11-01 00:00:00]}]} =
               Stores.scanned([], 1, ~N[2026-11-01 00:00:00], last)

      assert {:found, [{1, _}]} = Stores.scanned([{1, ~N[2026-11-01 00:00:00]}], 2, last, last)
      assert {:found, []} = Stores.scanned([], 1, ~N[2026-09-01 00:00:00], last)
    end

    test "with nothing copied yet, every entry is new" do
      assert {:more, [{0, ~N[1988-01-01 00:00:00]}]} =
               Stores.scanned([], 0, ~N[1988-01-01 00:00:00], nil)
    end
  end

  describe "fill_scanned/5" do
    @from ~N[2026-10-01 00:00:00]

    test "a history or snapshot goes on while its stamp is at or after the range's start" do
      assert {:more, [{1, @from}]} = Stores.fill_scanned([], 1, @from, :history, @from)

      assert {:found, [{1, @from}]} =
               Stores.fill_scanned([{1, @from}], 2, ~N[2026-09-30 23:59:59], :snapshot, @from)
    end

    test "a load-survey day goes on while the day ends after the range's start" do
      assert {:more, [{0, ~N[2026-09-30 00:00:00]}]} =
               Stores.fill_scanned(
                 [],
                 0,
                 ~N[2026-09-30 00:00:00],
                 :load_survey,
                 ~N[2026-09-30 12:00:00]
               )

      assert {:found, []} =
               Stores.fill_scanned([], 0, ~N[2026-09-30 00:00:00], :load_survey, @from)
    end

    test "before/2 keeps the entries stamped before the range's end" do
      found = [{1, ~N[2026-11-01 00:00:00]}, {2, ~N[2026-10-31 23:59:59]}, {3, @from}]
      assert Stores.before(found, ~N[2026-11-01 00:00:00]) == tl(found)
    end
  end

  describe "gone_before/4" do
    @from ~N[2026-10-01 00:00:00]
    @to ~N[2026-11-01 00:00:00]

    test "a scan that reached an older entry leaves nothing gone" do
      assert Stores.gone_before(:older, [{1, ~N[2026-10-15 00:00:00]}], @from, @to) == nil
      assert Stores.gone_before(:older, [], @from, @to) == nil
    end

    test "a scan out of slots: its oldest entry inside the range, else the range's end" do
      assert Stores.gone_before(:exhausted, [{1, @to}, {2, ~N[2026-10-17 00:00:00]}], @from, @to) ==
               ~N[2026-10-17 00:00:00]

      assert Stores.gone_before(:exhausted, [{1, ~N[2026-11-02 00:00:00]}, {2, @to}], @from, @to) ==
               @to

      assert Stores.gone_before(:exhausted, [], @from, @to) == @to
    end

    test "a scan out of slots whose oldest entry is at or before the range's start leaves nothing gone" do
      assert Stores.gone_before(
               :exhausted,
               [{1, ~N[2026-10-02 00:00:00]}, {2, @from}],
               @from,
               @to
             ) ==
               nil

      # A load-survey day that starts before the range and ends inside it.
      assert Stores.gone_before(
               :exhausted,
               [{0, ~N[2026-09-30 00:00:00]}],
               ~N[2026-09-30 12:00:00],
               @to
             ) ==
               nil
    end
  end

  describe "due/2" do
    test "oldest first; a load-survey day once per parameter, the last marked" do
      found = [{0, ~N[2026-11-16 00:00:00]}, {1, ~N[2026-11-15 00:00:00]}]
      assert Stores.due(found, nil) == Enum.reverse(found)

      a = %{number: 0, key: "a"}
      b = %{number: 1, key: "b"}

      assert Stores.due(found, [a, b]) == [
               {1, ~N[2026-11-15 00:00:00], a, false},
               {1, ~N[2026-11-15 00:00:00], b, true},
               {0, ~N[2026-11-16 00:00:00], a, false},
               {0, ~N[2026-11-16 00:00:00], b, true}
             ]
    end
  end

  describe "parameters/2" do
    test "those the profile names and the mask supports, never an unnamed bit", ctx do
      mask = Enum.reduce([0, 6, 11, 63], 0, &Bitwise.bor(&2, Bitwise.bsl(1, &1)))
      assert Enum.map(Stores.parameters(ctx.p500.stored.load_survey, mask), & &1.number) == [0]
    end
  end

  describe "runs/1" do
    test "adjoining spans merge, others stay apart, and none is longer than a request" do
      assert Stores.runs([{10, 2}, {4, 2}, {6, 2}, {20, 1}]) == [{4, 4}, {10, 2}, {20, 1}]
      assert Stores.runs([{0, 125}, {125, 5}]) == [{0, 125}, {125, 5}]
      assert Stores.runs([{0, 100}, {100, 100}]) == [{0, 125}, {125, 75}]
    end

    test "a 440 history reads its stamp and mask together, and the registers in two runs", ctx do
      assert Stores.runs(Stores.block_spans(ctx.p440.stored.history)) == [
               {521, 3},
               {526, 4},
               {534, 16}
             ]
    end

    test "a 500 history leaves out the net register between its runs", ctx do
      assert Stores.runs(Stores.block_spans(ctx.p500.stored.history)) ==
               [{901, 2}, {911, 4}, {927, 16}, {945, 12}]
    end

    test "a day's first intervals in reads of per_request intervals; none, no read", ctx do
      assert Stores.value_runs(ctx.p440.stored.load_survey, 48) == [{807, 96}]
      assert Stores.value_runs(ctx.p440.stored.load_survey, 96) == [{807, 96}, {903, 96}]
      assert Stores.value_runs(ctx.p500.stored.load_survey, 96) == [{5022, 120}, {5142, 72}]
      assert Stores.value_runs(ctx.p500.stored.load_survey, 20) == [{5022, 40}]
      assert Stores.value_runs(ctx.p500.stored.load_survey, 0) == []
    end
  end
end
