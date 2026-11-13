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

  describe "parse/1" do
    test "parse rejects unknown fields, a missing source and an empty accept list" do
      assert {:error, "unknown field" <> _} = Identity.parse(%{"model" => %{}})

      assert {:error, "identity.energy_unit: source" <> _} =
               Identity.parse(%{"energy_unit" => Map.delete(@unit, "source")})

      assert {:error, "identity.serial: source" <> _} =
               Identity.parse(%{"serial" => Map.delete(@serial, "source")})

      assert {:error, "identity.product_code: accept" <> _} =
               Identity.parse(%{"product_code" => %{@product | "accept" => []}})

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
