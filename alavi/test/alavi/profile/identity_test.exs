defmodule Alavi.Profile.IdentityTest do
  use ExUnit.Case, async: true

  alias Alavi.Profile.Identity

  @product %{
    "table" => "holding",
    "address" => 19,
    "count" => 6,
    "accept" => ["ELITE440-445", "ELITE440-446"],
    "source" => "s",
    "verified_on_device" => nil
  }
  @serial %{
    "table" => "holding",
    "address" => 0,
    "count" => 4,
    "source" => "s",
    "verified_on_device" => nil
  }
  @unit %{
    "table" => "holding",
    "address" => 1957,
    "part" => "word",
    "expect" => 3,
    "absent_ok" => false,
    "source" => "s",
    "verified_on_device" => nil
  }
  @none %{serial: nil, product_code: nil}

  defp identity!(json) do
    {:ok, identity} = Identity.parse(json)
    identity
  end

  # Text as read from a meter: big-endian words, NUL-padded to `count`.
  defp words(text, count \\ 6) do
    padded = text <> :binary.copy(<<0>>, count * 2 - byte_size(text))
    for <<w::16 <- padded>>, do: w
  end

  describe "verdict/2" do
    test "an empty identity checks nothing and observes nothing" do
      identity = identity!(%{})
      assert Identity.empty?(identity)
      assert Identity.reads(identity) == []
      assert Identity.verdict(identity, %{}) == {:ok, @none}
    end

    test "an accepted product code passes, NUL padding and all, and is observed" do
      identity = identity!(%{"product_code" => @product})

      assert Identity.verdict(identity, %{product_code: {:ok, words("ELITE440-446")}}) ==
               {:ok, %{@none | product_code: "ELITE440-446"}}
    end

    test "another product code is a mismatch that names both, and is still observed" do
      identity = identity!(%{"product_code" => @product})

      assert {{:mismatch, detail}, %{product_code: "ELITE440-444"}} =
               Identity.verdict(identity, %{product_code: {:ok, words("ELITE440-444")}})

      assert detail =~ ~s("ELITE440-444")
      assert detail =~ "ELITE440-445, ELITE440-446"
    end

    test "any printable serial passes and is observed, trimmed" do
      identity = identity!(%{"serial" => @serial})

      for {text, seen} <- [{"SIM-1", "SIM-1"}, {" SIM 1  ", "SIM 1"}, {"SIM00001", "SIM00001"}] do
        assert Identity.verdict(identity, %{serial: {:ok, words(text, 4)}}) ==
                 {:ok, %{@none | serial: seen}}
      end
    end

    test "a serial that cannot label a reading is a mismatch, observed as nil" do
      identity = identity!(%{"serial" => @serial})

      for bytes <- [<<0::64>>, "SIM" <> <<0xC9>> <> "001", "SI" <> <<0>> <> "M1"] do
        assert {{:mismatch, "serial " <> _}, @none} =
                 Identity.verdict(identity, %{serial: {:ok, words(bytes, 4)}})
      end
    end

    test "a failed serial read is the read's error, with what else was observed" do
      identity = identity!(%{"product_code" => @product, "serial" => @serial})
      results = %{product_code: {:ok, words("ELITE440-445")}, serial: {:error, :timeout}}

      assert Identity.verdict(identity, results) ==
               {{:error, :timeout}, %{@none | product_code: "ELITE440-445"}}
    end

    test "a word-sized unit code must equal expect" do
      identity = identity!(%{"energy_unit" => @unit})
      assert Identity.verdict(identity, %{energy_unit: {:ok, [3]}}) == {:ok, @none}
      assert {{:mismatch, _}, @none} = Identity.verdict(identity, %{energy_unit: {:ok, [6]}})
    end

    test "without absent_ok, a missing unit register is the read's error" do
      identity = identity!(%{"energy_unit" => @unit})

      assert Identity.verdict(identity, %{energy_unit: {:error, {:exception, 2}}}) ==
               {{:error, {:exception, 2}}, @none}
    end

    test "absent_ok accepts only exception 02, not other failures" do
      identity = identity!(%{"energy_unit" => %{@unit | "absent_ok" => true}})
      assert Identity.verdict(identity, %{energy_unit: {:error, {:exception, 2}}}) == {:ok, @none}

      assert Identity.verdict(identity, %{energy_unit: {:error, {:exception, 4}}}) ==
               {{:error, {:exception, 4}}, @none}
    end

    test "the product code decides first, and the serial is observed regardless" do
      identity =
        identity!(%{"product_code" => @product, "serial" => @serial, "energy_unit" => @unit})

      results = %{
        product_code: {:ok, words("ELITE440-444")},
        serial: {:ok, words("SIM-1", 4)},
        energy_unit: {:ok, [6]}
      }

      assert {{:mismatch, "product code" <> _}, %{serial: "SIM-1"}} =
               Identity.verdict(identity, results)
    end
  end

  describe "observed/2" do
    test "reads cut short observe what was read, and nil for the rest" do
      identity =
        identity!(%{"product_code" => @product, "serial" => @serial, "energy_unit" => @unit})

      assert Identity.observed(identity, %{}) == @none

      assert Identity.observed(identity, %{
               product_code: {:ok, words("ELITE440-445")},
               serial: {:ok, words("SIM-1", 4)}
             }) == %{serial: "SIM-1", product_code: "ELITE440-445"}

      assert Identity.observed(identity, %{product_code: {:error, :timeout}}) == @none
    end
  end

  describe "reads/1" do
    test "reads list the product code, then the serial, then the energy unit" do
      identity =
        identity!(%{"energy_unit" => @unit, "serial" => @serial, "product_code" => @product})

      assert Identity.reads(identity) == [
               {:product_code, :holding, 19, 6},
               {:serial, :holding, 0, 4},
               {:energy_unit, :holding, 1957, 1}
             ]
    end
  end

  describe "requests/1" do
    defp at(json, address, count \\ nil) do
      json = Map.put(json, "address", address)
      if count, do: Map.put(json, "count", count), else: json
    end

    test "an empty identity makes no request" do
      assert Identity.requests(identity!(%{})) == []
    end

    test "reads with at most 15 registers between them share one request, in reads/1 order" do
      identity =
        identity!(%{
          "serial" => at(@serial, 0, 4),
          "product_code" => at(@product, 19, 6),
          "energy_unit" => at(@unit, 35)
        })

      assert Identity.requests(identity) == [
               {:holding, 0, 36,
                [
                  {:product_code, :holding, 19, 6},
                  {:serial, :holding, 0, 4},
                  {:energy_unit, :holding, 35, 1}
                ]}
             ]
    end

    test "a unit setting the meter may lack is a request of its own" do
      identity =
        identity!(%{
          "serial" => at(@serial, 0, 4),
          "product_code" => at(@product, 19, 6),
          "energy_unit" => %{at(@unit, 35) | "absent_ok" => true}
        })

      assert Identity.requests(identity) == [
               {:holding, 0, 25, [{:product_code, :holding, 19, 6}, {:serial, :holding, 0, 4}]},
               {:holding, 35, 1, [{:energy_unit, :holding, 35, 1}]}
             ]
    end

    test "16 registers between reads part them; requests follow their first read" do
      identity =
        identity!(%{
          "energy_unit" => at(@unit, 0),
          "serial" => at(@serial, 17, 4),
          "product_code" => at(@product, 21, 6)
        })

      assert Identity.requests(identity) == [
               {:holding, 17, 10, [{:product_code, :holding, 21, 6}, {:serial, :holding, 17, 4}]},
               {:holding, 0, 1, [{:energy_unit, :holding, 0, 1}]}
             ]
    end

    test "a request never passes 125 registers" do
      at_end = fn count ->
        identity!(%{"serial" => at(@serial, 0, 110), "product_code" => at(@product, 110, count)})
      end

      assert [{:holding, 0, 125, [_, _]}] = Identity.requests(at_end.(15))
      assert [{:holding, 110, 16, _}, {:holding, 0, 110, _}] = Identity.requests(at_end.(16))
    end

    test "reads in different tables are never merged" do
      identity =
        identity!(%{
          "serial" => at(@serial, 0, 4),
          "product_code" => %{@product | "table" => "input", "address" => 4}
        })

      assert [{:input, 4, 6, [{:product_code, _, _, _}]}, {:holding, 0, 4, [{:serial, _, _, _}]}] =
               Identity.requests(identity)
    end
  end

  describe "split/2" do
    test "each read gets its own words out of a merged reply" do
      request =
        {:holding, 10, 8, [{:product_code, :holding, 15, 3}, {:serial, :holding, 10, 2}]}

      assert Identity.split(request, [1, 2, 3, 4, 5, 6, 7, 8]) == %{
               product_code: {:ok, [6, 7, 8]},
               serial: {:ok, [1, 2]}
             }
    end
  end

  describe "parse/1" do
    test "parse rejects unknown fields, a missing source and an accept list that cannot match" do
      assert {:error, "unknown field" <> _} = Identity.parse(%{"model" => %{}})

      assert {:error, "identity.energy_unit: source" <> _} =
               Identity.parse(%{"energy_unit" => Map.delete(@unit, "source")})

      assert {:error, "identity.serial: source" <> _} =
               Identity.parse(%{"serial" => Map.delete(@serial, "source")})

      assert {:error, "identity.product_code: accept" <> _} =
               Identity.parse(%{"product_code" => %{@product | "accept" => []}})

      for code <- ["ELITE·440", "ELITE\t440", ""] do
        assert {:error, "identity.product_code: accept must list" <> _} =
                 Identity.parse(%{"product_code" => %{@product | "accept" => [code]}})
      end

      assert {:error, "identity.serial: unknown field(s) accept"} =
               Identity.parse(%{"serial" => Map.put(@serial, "accept", ["X"])})
    end

    test "every check needs verified_on_device: null or a date" do
      for {check, json} <- [
            {"product_code", @product},
            {"serial", @serial},
            {"energy_unit", @unit}
          ] do
        assert {:error, "identity." <> _} =
                 Identity.parse(%{check => Map.delete(json, "verified_on_device")})

        assert {:ok, %{} = identity} =
                 Identity.parse(%{check => %{json | "verified_on_device" => "2026-11-13"}})

        assert %{verified_on_device: ~D[2026-11-13]} =
                 Map.fetch!(identity, String.to_existing_atom(check))
      end
    end
  end
end
