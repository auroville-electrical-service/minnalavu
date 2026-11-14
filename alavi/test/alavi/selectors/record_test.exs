defmodule Alavi.Selectors.RecordTest do
  use ExUnit.Case, async: true

  alias Alavi.Selectors.Record

  @endpoint %{host: "127.0.0.1", port: 5020}

  defp record do
    %Record{
      endpoint: @endpoint,
      unit_id: 3,
      model: "elite_500",
      selectors: [
        %{name: :history, value: 0, bound: 6},
        %{name: :snapshot, value: 9, bound: 52}
      ]
    }
  end

  defp owed(changes), do: record() |> Record.encode() |> JSON.decode!() |> Map.merge(changes)

  describe "parse/2" do
    test "reads back what encode/1 wrote" do
      assert Record.parse(Record.encode(record()), @endpoint) == {:ok, record()}
    end

    test "refuses a record that is not whole" do
      text = Record.encode(record())
      cut = binary_part(text, 0, byte_size(text) - 3)
      assert {:error, "invalid JSON" <> _} = Record.parse(cut, @endpoint)
      assert {:error, _} = Record.parse("", @endpoint)
    end

    test "refuses another endpoint's record, another format, and unknown fields" do
      text = Record.encode(record())
      assert {:error, "names endpoint" <> _} = Record.parse(text, %{@endpoint | port: 502})

      for json <- [
            owed(%{"format" => "alavi-selector-restore.v2"}),
            owed(%{"extra" => 1}),
            Map.delete(owed(%{}), "format")
          ] do
        assert {:error, _} = Record.parse(JSON.encode!(json), @endpoint), inspect(json)
      end
    end

    test "refuses a selector not on the model's allowlist, a value outside a word, and repeats" do
      [history, snapshot] = owed(%{})["selectors"]

      for selectors <- [
            [],
            [%{history | "name" => "clock"}],
            [%{history | "value" => 0x10000}],
            [%{history | "value" => -1}],
            [%{history | "bound" => "6"}],
            [Map.delete(history, "bound")],
            [history, history],
            [history, Map.put(snapshot, "extra", 1)]
          ] do
        json = JSON.encode!(owed(%{"selectors" => selectors}))
        assert {:error, _} = Record.parse(json, @endpoint), inspect(selectors)
      end

      assert {:error, _} = Record.parse(JSON.encode!(owed(%{"model" => "elite_300"})), @endpoint)
      assert {:error, _} = Record.parse(JSON.encode!(owed(%{"unit_id" => 0})), @endpoint)
    end
  end

  describe "parse_left/2" do
    test "reads back what encode_left/2 wrote, and an empty one" do
      left = %{{3, "elite_500", :history} => 0, {1, "elite_440", :snapshot} => 2}
      assert Record.parse_left(Record.encode_left(@endpoint, left), @endpoint) == {:ok, left}
      assert Record.parse_left(Record.encode_left(@endpoint, %{}), @endpoint) == {:ok, %{}}
    end

    test "an owed record's values, as left" do
      assert Record.left(record()) == %{
               {3, "elite_500", :history} => 0,
               {3, "elite_500", :snapshot} => 9
             }
    end

    test "refuses another endpoint's, an owed record, and a selector of another model" do
      text = Record.encode_left(@endpoint, %{{3, "elite_500", :history} => 0})
      assert {:error, _} = Record.parse_left(text, %{@endpoint | host: "127.0.0.2"})
      assert {:error, _} = Record.parse_left(Record.encode(record()), @endpoint)

      json =
        text
        |> JSON.decode!()
        |> Map.put("selectors", [
          %{"unit_id" => 3, "model" => "elite_500", "name" => "load_survey", "value" => 0}
        ])

      assert {:error, _} = Record.parse_left(JSON.encode!(json), @endpoint)
    end
  end
end
