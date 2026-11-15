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

    property "whole numbers stored as f32 decode to themselves" do
      check all whole <- integer(0..1_000_000), order <- member_of([:high_first, :low_first]) do
        register = register(:f32, order, nil)
        value = Decimal.new(whole)

        assert {:ok, decoded} =
                 Decode.value(register, Simulator.Encode.words(spec(register), value))

        assert Decimal.equal?(decoded, value)
      end
    end

    # The parse back goes through f64 for the f32 case: double rounding could in
    # principle mislead it, but only for a decimal within 2^-53 of an f32 midpoint.
    property "a float decodes to a decimal that gives back its bits, and none shorter does" do
      check all type <- member_of([:f32, :f64]),
                bits <- integer(1..max_bits(type)),
                max_runs: 2_000 do
        register = register(type, :high_first, nil)
        assert {:ok, value} = Decode.value(register, words(type, bits))
        assert bits(type, value) == bits

        for shorter <- shorter(value) do
          refute bits(type, shorter) == bits, "#{shorter} is shorter than #{value}"
        end
      end
    end

    property "any words decode to a value or an error, never a raise" do
      check all type <- member_of([:u16, :i16, :u32, :i32, :u64, :f32, :f64]),
                order <- member_of([:high_first, :low_first]),
                decimals <- integer(0..9),
                words <- list_of(integer(0..0xFFFF), length: Register.word_count(type)),
                max_runs: 2_000 do
        decimals = if type in [:f32, :f64], do: nil, else: decimals
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

    test "every profile entry gives the fixture's value", ctx do
      for c <- ctx.fixture["profiles"] do
        register = profile_register(ctx.profiles, c)
        assert {:ok, value} = Decode.value(register, c["raw_words"]), c["why"]
        assert Decimal.to_string(value, :normal) == c["value"], c["why"]
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

    test "integers keep exactly decimals places, floats are never rounded" do
      for {words, expected} <- [{[0, 1234], "1.234"}, {[0, 1000], "1.000"}] do
        assert {:ok, exact} = Decode.value(register(:u32, :high_first, 3), words)
        assert Decimal.to_string(exact, :normal) == expected
      end

      for {words, expected} <- [{[0x3E00, 0], "0.125"}, {[0x3EC0, 0], "0.375"}] do
        assert {:ok, value} = Decode.value(register(:f32, :high_first, nil), words)
        assert Decimal.to_string(value, :normal) == expected
      end
    end

    test "NaN is an error, not a value" do
      assert {:error, :not_finite} = Decode.value(register(:f32, :high_first, nil), [0x7FC0, 0])
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
      kind: :cumulative,
      source: nil,
      placeholder: true,
      verified_on_device: nil
    }
  end

  defp profile_register(profiles, %{"profile" => name, "register_key" => key}) do
    {:ok, register} = Alavi.Profile.register(Map.fetch!(profiles, name), key)
    register
  end

  # Below the largest finite value, whose shorter neighbours overflow.
  defp max_bits(:f32), do: 0x7F000000
  defp max_bits(:f64), do: 0x7FE0000000000000

  defp words(:f32, bits), do: for(<<(w::16 <- <<bits::32>>)>>, do: w)
  defp words(:f64, bits), do: for(<<(w::16 <- <<bits::64>>)>>, do: w)

  defp bits(:f32, value) do
    <<bits::32>> = <<parsed(value)::float-32>>
    bits
  end

  defp bits(:f64, value) do
    <<bits::64>> = <<parsed(value)::float-64>>
    bits
  end

  # Decimal.to_float/1 refuses subnormals; Erlang's own parse does not.
  defp parsed(%Decimal{sign: 1, coef: coef, exp: exp}),
    do: :erlang.binary_to_float("#{coef}.0e#{exp}")

  # The decimals of one fewer significant digit either side of `value`: if any
  # shorter decimal named the same bits, one of these would.
  defp shorter(value) do
    %Decimal{coef: coef, exp: exp} = Decimal.normalize(value)

    if coef < 10,
      do: [],
      else: Enum.map([:floor, :ceiling], &Decimal.round(value, -(exp + 1), &1))
  end

  defp spec(%Register{} = r), do: %{type: r.type, word_order: r.word_order, decimals: r.decimals}
end
