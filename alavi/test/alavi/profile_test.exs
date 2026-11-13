defmodule Alavi.ProfileTest do
  use ExUnit.Case, async: true

  alias Alavi.{Decode, Profile}

  @contract Path.expand("../../../contract", __DIR__)

  describe "parse/1" do
    test "every contract profile parses, and every entry names a source or is marked placeholder" do
      for path <- Path.wildcard(Path.join(@contract, "profiles/*.json")) do
        assert {:ok, profile} = Profile.load(path)
        assert Enum.all?(profile.registers, &(&1.source != nil or &1.placeholder))
      end
    end

    test "an entry with no source must be a placeholder" do
      json = profile_json(%{"source" => nil, "placeholder" => false})
      assert {:error, "registers[0]: source is null" <> _} = Profile.parse(json)
    end

    test "a source must be listed in sources, and listed once" do
      assert {:error, ~s(source "y" is not in sources)} =
               Profile.parse(profile_json(%{"source" => "y", "placeholder" => false}))

      json = %{profile_json(%{}) | "sources" => ["x", "x"]}
      assert {:error, "sources lists an ID more than once"} = Profile.parse(json)
    end

    test "an identity check's source must be listed in sources" do
      unit = %{
        "table" => "holding",
        "address" => 0,
        "part" => "word",
        "expect" => 1,
        "absent_ok" => false,
        "source" => "y",
        "verified_on_device" => nil
      }

      json = %{profile_json(%{}) | "identity" => %{"energy_unit" => unit}}
      assert {:error, ~s(source "y" is not in sources)} = Profile.parse(json)
    end

    test "a source is an ID, not a document name" do
      json = %{profile_json(%{}) | "sources" => ["Vendor map"]}
      assert {:error, "sources: source \"Vendor map\" must be" <> _} = Profile.parse(json)
    end

    test "verified_on_device is null or a date" do
      assert {:ok, %{registers: [%{verified_on_device: ~D[2026-11-14]}]}} =
               Profile.parse(profile_json(%{"verified_on_device" => "2026-11-14"}))

      assert {:error, "registers[0]: verified_on_device must be" <> _} =
               Profile.parse(profile_json(%{"verified_on_device" => true}))
    end

    test "a profile with no sources is rejected" do
      json = %{profile_json(%{}) | "sources" => []}
      assert {:error, "expected schema_version" <> _} = Profile.parse(json)
    end

    test "an unknown data type is rejected" do
      assert {:error, "registers[0]: type" <> _} = Profile.parse(profile_json(%{"type" => "f16"}))
    end
  end

  test "contract fixture values decode from their raw words, under accepted product codes" do
    fixture =
      @contract |> Path.join("fixtures/batch.v1.basic.json") |> File.read!() |> JSON.decode!()

    for reading <- fixture["readings"] do
      {:ok, profile} = Profile.load(Path.join(@contract, "profiles/#{reading["profile"]}.json"))
      {:ok, register} = Profile.register(profile, reading["register_key"])

      assert {:ok, value} = Decode.value(register, reading["raw_words"])
      assert Decimal.to_string(value) == reading["value"]
      assert register.unit == reading["unit"]
      assert reading["product_code"] in profile.identity.product_code.accept
    end
  end

  defp profile_json(overrides) do
    entry =
      Map.merge(
        %{
          "key" => "e",
          "table" => "input",
          "address" => 0,
          "type" => "u32",
          "word_order" => "high_first",
          "decimals" => 0,
          "unit" => "kWh",
          "source" => nil,
          "placeholder" => true,
          "verified_on_device" => nil
        },
        overrides
      )

    %{
      "schema_version" => 1,
      "profile" => "test",
      "models" => ["Test"],
      "sources" => ["x"],
      "identity" => %{},
      "registers" => [entry]
    }
  end
end
