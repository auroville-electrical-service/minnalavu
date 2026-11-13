defmodule Alavi.DecodeTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Alavi.{Decode, Profile.Register}

  @ranges %{
    u16: 0..0xFFFF,
    i16: -0x8000..0x7FFF,
    u32: 0..0xFFFFFFFF,
    i32: -0x80000000..0x7FFFFFFF,
    u64: 0..0xFFFFFFFFFFFFFFFF
  }

  describe "value/2" do
    # Encoded by the simulator, decoded by alavi: two independent implementations.
    property "integer registers round-trip exactly through the simulator's encoder" do
      check all type <- member_of(Map.keys(@ranges)),
                raw <- integer(@ranges[type]),
                decimals <- integer(0..4),
                order <- member_of([:high_first, :low_first]) do
        register = register(type, order, decimals)
        value = Decimal.new(if(raw < 0, do: -1, else: 1), abs(raw), -decimals)
        words = Simulator.Encode.words(spec(register), value)

        assert {:ok, decoded} = Decode.value(register, words)
        assert Decimal.equal?(decoded, value)
      end
    end

    property "f32 registers decode to the stored value at the register's precision" do
      check all whole <- integer(0..1_000_000), order <- member_of([:high_first, :low_first]) do
        register = register(:f32, order, 1)
        value = Decimal.new(whole)

        assert {:ok, decoded} =
                 Decode.value(register, Simulator.Encode.words(spec(register), value))

        assert Decimal.equal?(decoded, value)
      end
    end

    property "any words decode to a value or an error, never a raise" do
      check all type <- member_of([:u16, :i16, :u32, :i32, :u64, :f32, :f64]),
                order <- member_of([:high_first, :low_first]),
                decimals <- integer(0..9),
                words <- list_of(integer(0..0xFFFF), length: Register.word_count(type)),
                max_runs: 2_000 do
        assert {status, _} = Decode.value(register(type, order, decimals), words)
        assert status in [:ok, :error]
      end
    end

    @fixture Path.expand("../../../contract/fixtures/register-decode.v1.json", __DIR__)
    @profiles Path.expand("../../../contract/profiles", __DIR__)

    setup do
      {:ok, profiles} = Alavi.Profile.load_dir(@profiles)
      %{"format" => "register-decode/1"} = fixture = @fixture |> File.read!() |> JSON.decode!()
      %{fixture: fixture, profiles: profiles}
    end

    test "every profile entry gives the fixture's value and unit", ctx do
      for c <- ctx.fixture["profiles"] do
        register = profile_register(ctx.profiles, c)
        assert {:ok, value} = Decode.value(register, c["raw_words"]), c["why"]

        assert {Decimal.to_string(value, :normal), register.unit} == {c["value"], c["unit"]},
               c["why"]
      end
    end

    test "every data type and word order gives the fixture's value", ctx do
      for c <- ctx.fixture["types"] do
        order = String.to_existing_atom(c["word_order"])
        register = register(String.to_existing_atom(c["type"]), order, c["decimals"])
        assert {:ok, value} = Decode.value(register, c["raw_words"]), c["why"]
        assert Decimal.to_string(value, :normal) == c["value"], c["why"]
      end
    end

    test "every no_value case is refused with the fixture's error", ctx do
      for c <- ctx.fixture["no_value"] do
        register = profile_register(ctx.profiles, c)
        error = String.to_existing_atom(c["error"])
        assert Decode.value(register, c["raw_words"]) == {:error, error}, c["why"]
      end
    end

    test "integers are divided by 10^decimals exactly, floats rounded half-even to decimals" do
      assert {:ok, exact} = Decode.value(register(:u32, :high_first, 3), [0, 1234])
      assert Decimal.to_string(exact, :normal) == "1.234"

      for {words, expected} <- [{[0x3E00, 0], "0.12"}, {[0x3EC0, 0], "0.38"}] do
        assert {:ok, value} = Decode.value(register(:f32, :high_first, 2), words)
        assert Decimal.to_string(value, :normal) == expected
      end
    end

    test "NaN is an error, not a value" do
      assert {:error, :not_finite} = Decode.value(register(:f32, :high_first, 1), [0x7FC0, 0])
    end

    test "wrong word order gives a different value" do
      register = register(:u32, :low_first, 0)
      assert {:ok, a} = Decode.value(register, [1, 2])
      assert {:ok, b} = Decode.value(%{register | word_order: :high_first}, [1, 2])
      refute Decimal.equal?(a, b)
    end

    test "wrong word count is an error" do
      assert {:error, :wrong_word_count} = Decode.value(register(:u32, :low_first, 0), [1])
    end
  end

  defp register(type, order, decimals) do
    %Register{
      key: "test",
      table: :holding,
      address: 0,
      type: type,
      word_order: order,
      decimals: decimals,
      unit: "kWh",
      source: nil,
      placeholder: true,
      verified_on_device: nil
    }
  end

  defp profile_register(profiles, %{"profile" => name, "register_key" => key}) do
    {:ok, register} = Alavi.Profile.register(Map.fetch!(profiles, name), key)
    register
  end

  defp spec(%Register{} = r), do: %{type: r.type, word_order: r.word_order, decimals: r.decimals}
end
