defmodule Alavi.Decode.StoredTest do
  use ExUnit.Case, async: true

  alias Alavi.Decode.Stored, as: Decode
  alias Alavi.Profile.Stored

  @fixture Path.expand("../../../../contract/fixtures/stored-decode.v1.json", __DIR__)
  @profiles Path.expand("../../../../contract/profiles", __DIR__)

  setup_all do
    {:ok, profiles} = Alavi.Profile.load_dir(@profiles)
    %{"format" => "stored-decode/1"} = fixture = @fixture |> File.read!() |> JSON.decode!()
    %{fixture: fixture, profiles: profiles}
  end

  describe "stored-decode.v1.json" do
    test "every stamp decodes to the fixture's meter time", ctx do
      for c <- ctx.fixture["stamps"] do
        profile = profile(ctx, c)
        assert {:ok, at} = Decode.stamp(stamp(profile, c["field"]), c["raw_words"]), c["why"]
        assert NaiveDateTime.to_iso8601(at) == c["meter_time"], c["why"]
      end
    end

    test "every mask names the fixture's bits, and leaves the rest unnamed", ctx do
      for c <- ctx.fixture["masks"] do
        profile = profile(ctx, c)
        [store, "mask"] = String.split(c["field"], ".")
        {mask, names} = mask(profile.stored, String.to_existing_atom(store))
        assert {:ok, n} = Decode.mask(mask, c["raw_words"]), c["why"]
        bits = Enum.filter(0..63, &Decode.set?(n, &1))

        named =
          for b <- bits, Map.has_key?(names, b), do: %{"bit" => b, "register_key" => names[b]}

        assert named == c["named"], c["why"]
        assert Enum.reject(bits, &Map.has_key?(names, &1)) == c["unnamed"], c["why"]
      end
    end

    test "every block gives the fixture's entries, unsupported and not_finite", ctx do
      for c <- ctx.fixture["blocks"] do
        block = Stored.section(profile(ctx, c).stored, String.to_existing_atom(c["store"]))

        assert {:ok, decoded} =
                 Decode.block(block, c["stamp_words"], c["mask_words"], c["registers"]),
               c["why"]

        assert NaiveDateTime.to_iso8601(decoded.meter_time) == c["meter_time"], c["why"]

        assert Enum.map(decoded.entries, fn {k, v} ->
                 %{"register_key" => k, "value" => text(v)}
               end) ==
                 c["entries"],
               c["why"]

        assert decoded.unsupported == c["unsupported"], c["why"]
        assert decoded.not_finite == c["not_finite"], c["why"]
      end
    end

    test "every load-survey day gives the fixture's intervals", ctx do
      for c <- ctx.fixture["load_survey"] do
        profile = profile(ctx, c)
        survey = profile.stored.load_survey

        assert Enum.any?(
                 survey.parameters,
                 &(&1.number == c["parameter"] and &1.key == c["register_key"])
               )

        clock = if c["clock_words"], do: {profile.meter_clock, c["clock_words"]}

        read = %{
          stamp: c["stamp_words"],
          interval: c["interval_words"],
          values: c["values_words"],
          clock: clock
        }

        assert {:ok, day} = Decode.day(survey, read), c["why"]
        assert day.interval_s == c["interval_s"], c["why"]

        assert Enum.map(day.entries, fn {t, v} ->
                 %{"meter_time" => iso(t), "value" => text(v)}
               end) ==
                 c["entries"],
               c["why"]

        assert Enum.map(day.not_finite, &iso/1) == c["not_finite"], c["why"]
        assert day.not_ended == c["not_ended"], c["why"]
      end
    end

    test "the current day read whole, past the meter's clock, is refused", ctx do
      c = Enum.find(ctx.fixture["load_survey"], & &1["clock_words"])
      profile = profile(ctx, c)
      whole = List.duplicate(0, 2 * div(1440, hd(c["interval_words"])))

      read = %{
        stamp: c["stamp_words"],
        interval: c["interval_words"],
        values: whole,
        clock: {profile.meter_clock, c["clock_words"]}
      }

      assert Decode.day(profile.stored.load_survey, read) == {:error, :wrong_word_count}
    end

    test "every no_value case is refused with the fixture's error", ctx do
      for c <- ctx.fixture["no_value"] do
        profile = profile(ctx, c)
        error = String.to_existing_atom(c["error"])
        assert refused(profile, c["field"], c["raw_words"]) == {:error, error}, c["why"]
      end
    end
  end

  defp profile(ctx, c) do
    profile = Map.fetch!(ctx.profiles, c["profile"])
    assert profile.version == c["profile_version"]
    profile
  end

  defp stamp(profile, "meter_clock"), do: profile.meter_clock

  defp stamp(profile, field) do
    [store, "stamp"] = String.split(field, ".")
    Stored.section(profile.stored, String.to_existing_atom(store)).stamp
  end

  defp mask(stored, :load_survey),
    do: {stored.load_survey.mask, Map.new(stored.load_survey.parameters, &{&1.number, &1.key})}

  defp mask(stored, store) do
    block = Stored.section(stored, store)
    {block.mask, Map.new(block.registers, &{&1.mask_bit, &1.key})}
  end

  defp refused(profile, field, words) do
    case String.split(field, ".") do
      [_store, "mask"] = [store, _] ->
        Decode.mask(elem(mask(profile.stored, String.to_existing_atom(store)), 0), words)

      ["load_survey", "interval"] ->
        Decode.interval(words)

      ["load_survey", "values"] ->
        Decode.values(profile.stored.load_survey, words)

      _stamp ->
        Decode.stamp(stamp(profile, field), words)
    end
  end

  defp text(value), do: Decimal.to_string(value, :normal)
  defp iso(at), do: NaiveDateTime.to_iso8601(at)
end
