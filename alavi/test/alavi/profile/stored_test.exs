defmodule Alavi.Profile.StoredTest do
  use ExUnit.Case, async: true

  alias Alavi.Profile
  alias Alavi.Profile.Stored

  @profiles Path.expand("../../../../contract/profiles", __DIR__)

  defp json(name), do: @profiles |> Path.join("#{name}.json") |> File.read!() |> JSON.decode!()

  defp change(json, path, value), do: put_in(json, Enum.map(path, &access/1), value)

  defp access(i) when is_integer(i), do: Access.at(i)
  defp access(key), do: key

  describe "parse/1" do
    test "each contract profile's stored section and meter clock parse, at PDU addresses" do
      {:ok, p440} = Profile.parse(json("elite_440"))
      {:ok, p500} = Profile.parse(json("elite_500"))

      assert %{address: 173, word_order: :low_first, epoch: ~N[1988-01-01 00:00:00]} =
               p440.meter_clock

      assert %{address: 173, word_order: :high_first, epoch: ~N[2000-01-01 00:00:00]} =
               p500.meter_clock

      assert %{selector: :history, available: 519, mask: %{address: 523, type: :u16}} =
               p440.stored.history

      assert %{mask: nil, available: 899} = p500.stored.history
      assert length(p440.stored.history.registers) == 10
      assert Enum.all?(p440.stored.history.registers, &is_integer(&1.mask_bit))

      assert %{day: :load_survey_day, parameter: :load_survey_parameter, interval: 57} =
               p440.stored.load_survey

      assert %{mask: %{type: :u64, word_order: :high_first}, values: %{per_request: 60}} =
               p500.stored.load_survey

      refute Enum.any?(p500.stored.load_survey.parameters, &(&1.number == 6))
    end

    test "a load-survey quantity is never cumulative, and no other store's is per interval" do
      survey =
        change(
          json("elite_440"),
          ["stored", "load_survey", "parameters", 0, "kind"],
          "cumulative"
        )

      assert {:error, message} = Profile.parse(survey)
      assert message =~ "cannot be cumulative"

      history =
        change(json("elite_440"), ["stored", "history", "registers", 0, "kind"], "interval")

      assert {:error, message} = Profile.parse(history)
      assert message =~ "only the load survey is per interval"
    end

    test "every register has a mask bit exactly when its block has a mask" do
      json = json("elite_440")
      {_, bare} = pop_in(json, ["stored", "history", "mask"])
      assert {:error, message} = Profile.parse(bare)
      assert message =~ "mask_bit exactly when there is a mask"
    end

    test "a selector must be the allowlisted one for its store, and a field must be known" do
      wrong = change(json("elite_440"), ["stored", "snapshot", "selector"], "history")
      assert {:error, message} = Profile.parse(wrong)
      assert message =~ ~s(selector must be "snapshot")

      extra = change(json("elite_500"), ["stored", "history", "reason"], %{})
      assert {:error, message} = Profile.parse(extra)
      assert message =~ "unknown field(s) reason"
    end

    test "a unit outside the vocabulary, or a source not in sources, is refused" do
      unit = change(json("elite_500"), ["stored", "snapshot", "registers", 0, "unit"], "MWh")
      assert {:error, message} = Profile.parse(unit)
      assert message =~ "unit must be one of"

      source =
        change(json("elite_500"), ["stored", "load_survey", "stamp", "source"], "elite_500-z")

      assert {:error, ~s(source "elite_500-z" is not in sources)} = Profile.parse(source)
    end

    test "a values read longer than one request allows is refused" do
      long = change(json("elite_440"), ["stored", "load_survey", "values", "per_request"], 63)
      assert {:error, message} = Profile.parse(long)
      assert message =~ "per_request must be an integer in 1..62"
    end

    test "section/2 gives a store's section" do
      {:ok, %{stored: stored}} = Profile.parse(json("elite_440"))
      assert Stored.section(stored, :snapshot).selector == :snapshot
      assert Stored.section(stored, :load_survey).day == :load_survey_day
    end
  end
end
