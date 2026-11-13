defmodule Alavi.Profile.IdentityTest do
  use ExUnit.Case, async: true

  alias Alavi.Profile.Identity

  @product %{
    "table" => "holding",
    "address" => 19,
    "count" => 6,
    "accept" => ["ELITE440-445", "ELITE440-446"],
    "source" => "s"
  }
  @unit %{
    "table" => "holding",
    "address" => 1957,
    "part" => "word",
    "expect" => 3,
    "absent_ok" => false,
    "source" => "s"
  }

  defp identity!(json) do
    {:ok, identity} = Identity.parse(json)
    identity
  end

  # "ELITE440-445" as read from a meter: 6 big-endian words.
  defp words(code), do: for(<<w::16 <- String.pad_trailing(code, 12, <<0>>)>>, do: w)

  describe "verdict/2" do
    test "an empty identity checks nothing" do
      identity = identity!(%{})
      assert Identity.empty?(identity)
      assert Identity.reads(identity) == []
      assert Identity.verdict(identity, %{}) == :ok
    end

    test "an accepted product code passes, NUL padding and all" do
      identity = identity!(%{"product_code" => @product})
      assert Identity.verdict(identity, %{product_code: {:ok, words("ELITE440-446")}}) == :ok
    end

    test "another product code is a mismatch that names both" do
      identity = identity!(%{"product_code" => @product})

      assert {:mismatch, detail} =
               Identity.verdict(identity, %{product_code: {:ok, words("ELITE440-444")}})

      assert detail =~ ~s("ELITE440-444")
      assert detail =~ "ELITE440-445, ELITE440-446"
    end

    test "a word-sized unit code must equal expect" do
      identity = identity!(%{"energy_unit" => @unit})
      assert Identity.verdict(identity, %{energy_unit: {:ok, [3]}}) == :ok
      assert {:mismatch, _} = Identity.verdict(identity, %{energy_unit: {:ok, [6]}})
    end

    test "without absent_ok, a missing unit register is the read's error" do
      identity = identity!(%{"energy_unit" => @unit})

      assert Identity.verdict(identity, %{energy_unit: {:error, {:exception, 2}}}) ==
               {:error, {:exception, 2}}
    end

    test "absent_ok accepts only exception 02, not other failures" do
      identity = identity!(%{"energy_unit" => %{@unit | "absent_ok" => true}})
      assert Identity.verdict(identity, %{energy_unit: {:error, {:exception, 2}}}) == :ok

      assert Identity.verdict(identity, %{energy_unit: {:error, {:exception, 4}}}) ==
               {:error, {:exception, 4}}
    end

    test "the product code decides first" do
      identity = identity!(%{"product_code" => @product, "energy_unit" => @unit})

      results = %{product_code: {:ok, words("ELITE440-444")}, energy_unit: {:ok, [6]}}
      assert {:mismatch, "product code" <> _} = Identity.verdict(identity, results)
    end
  end

  describe "reads/1" do
    test "reads list the product code before the energy unit" do
      identity = identity!(%{"product_code" => @product, "energy_unit" => @unit})

      assert Identity.reads(identity) == [
               {:product_code, :holding, 19, 6},
               {:energy_unit, :holding, 1957, 1}
             ]
    end
  end

  describe "parse/1" do
    test "parse rejects unknown fields, a missing source and an empty accept list" do
      assert {:error, "unknown field" <> _} = Identity.parse(%{"serial" => %{}})

      assert {:error, "identity.energy_unit: source" <> _} =
               Identity.parse(%{"energy_unit" => Map.delete(@unit, "source")})

      assert {:error, "identity.product_code: accept" <> _} =
               Identity.parse(%{"product_code" => %{@product | "accept" => []}})
    end
  end
end
