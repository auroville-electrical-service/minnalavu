defmodule Alavi.Profile.FirmwareTest do
  use ExUnit.Case, async: true

  alias Alavi.Profile
  alias Alavi.Profile.Firmware

  @fixture Path.expand("../../../../contract/fixtures/firmware-names.v1.json", __DIR__)
  @profiles Path.expand("../../../../contract/profiles", __DIR__)

  @entry %{
    "table" => "holding",
    "address" => 4,
    "count" => 4,
    "type" => "ascii",
    "source" => "s",
    "verified_on_device" => nil
  }
  @json %{
    "software" => @entry,
    "firmware_1" => @entry,
    "firmware_2" => @entry,
    "modbus_version" => %{@entry | "count" => 1, "type" => "hex"}
  }

  setup_all do
    {:ok, profiles} = Profile.load_dir(@profiles)
    %{"format" => "firmware-names/1"} = fixture = @fixture |> File.read!() |> JSON.decode!()
    %{fixture: fixture, profiles: profiles}
  end

  describe "parse/1" do
    test "every contract profile has all four names, each citing a listed source", ctx do
      assert map_size(ctx.profiles) == 2

      for {name, profile} <- ctx.profiles do
        assert %Firmware{} = profile.firmware, name
        assert Enum.all?(Firmware.sources(profile.firmware), &(&1 in profile.sources)), name
      end
    end

    test "every name is required" do
      assert {:error, "firmware.firmware_2: is missing"} =
               Firmware.parse(Map.delete(@json, "firmware_2"))
    end

    test "an unknown name, or an identity field such as accept or expect, is refused" do
      assert {:error, "unknown field(s) hardware"} =
               Firmware.parse(Map.put(@json, "hardware", @entry))

      for field <- ["accept", "expect"] do
        json = %{@json | "software" => Map.put(@entry, field, ["X"])}
        assert {:error, "firmware.software: unknown field(s) " <> ^field} = Firmware.parse(json)
      end
    end

    test "an unknown type is refused" do
      json = %{@json | "software" => %{@entry | "type" => "u16"}}
      assert {:error, "firmware.software: type must be one of" <> _} = Firmware.parse(json)
    end

    test "a profile's firmware sources must be listed in its sources" do
      json =
        @profiles
        |> Path.join("elite_440.json")
        |> File.read!()
        |> JSON.decode!()
        |> put_in(["firmware", "software", "source"], "elite_440-z")

      assert {:error, ~s(source "elite_440-z" is not in sources)} = Profile.parse(json)
    end

    test "a profile without a firmware section reads no names" do
      json =
        @profiles
        |> Path.join("elite_500.json")
        |> File.read!()
        |> JSON.decode!()
        |> Map.delete("firmware")

      assert {:ok, %Profile{firmware: nil}} = Profile.parse(json)
    end
  end

  describe "reads/1" do
    test "each profile reads what the fixture lists, in order", ctx do
      for {name, reads} <- ctx.fixture["reads"] do
        listed =
          for {key, table, address, count} <- Firmware.reads(ctx.profiles[name].firmware),
              do: [Atom.to_string(key), Atom.to_string(table), address, count]

        assert listed == reads, name
      end
    end
  end

  describe "decode/2" do
    test "every fixture case gives its value or is refused", ctx do
      for c <- ctx.fixture["cases"] do
        entry =
          Map.fetch!(ctx.profiles[c["profile"]].firmware, String.to_existing_atom(c["name"]))

        label = "#{c["profile"]} #{c["name"]}: #{c["why"]}"
        assert wire(Firmware.decode(entry, c["words"])) == expected(c), label
      end
    end
  end

  defp expected(%{"value" => value}), do: %{"value" => value}
  defp expected(%{"refused" => reason}), do: %{"refused" => reason}

  defp wire({:ok, text}), do: %{"value" => text}
  defp wire({:error, reason}), do: %{"refused" => Atom.to_string(reason)}
end
