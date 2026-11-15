defmodule Alavi.Config.DigestTest do
  use ExUnit.Case, async: true

  alias Alavi.Config.Digest
  alias Alavi.ConfigCases

  @digests ConfigCases.read_json("fixtures/config.v1.digests.json")["cases"]

  defp document(%{"changes" => changes}),
    do: Enum.reduce(changes, ConfigCases.basic(), &ConfigCases.change(&2, &1))

  describe "canonical/1" do
    for %{"name" => name} = c <- @digests do
      @case c
      test "the contract's case: #{name}" do
        assert Digest.canonical(document(@case)) == {:ok, @case["canonical"]}
      end
    end

    test "keys sorted by their bytes, whatever order they were decoded in" do
      assert Digest.canonical(%{"b" => 1, "B" => [true, false, nil], "a" => %{}}) ==
               {:ok, ~S({"B":[true,false,null],"a":{},"b":1})}
    end

    test "a number that is not an integer has no canonical form here" do
      assert {:error, reason} = Digest.canonical(%{"endpoints" => [%{"port" => 502.0}]})
      assert reason =~ "502.0"
    end
  end

  describe "digest/1" do
    for %{"name" => name} = c <- @digests do
      @case c
      test "the contract's case: #{name}" do
        assert Digest.digest(document(@case)) == {:ok, @case["digest"]}
      end
    end

    test "the same document decoded from text that is not canonical gives the same digest" do
      [basic | _] = @digests
      text = ConfigCases.basic() |> JSON.encode_to_iodata!() |> IO.iodata_to_binary()
      spaced = String.replace(text, ",", ", ")
      assert Digest.digest(JSON.decode!(spaced)) == {:ok, basic["digest"]}
    end
  end
end
