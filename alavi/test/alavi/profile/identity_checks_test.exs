defmodule Alavi.Profile.IdentityChecksTest do
  @moduledoc "`contract/fixtures/identity-checks.v1.json`, under the real profiles."
  use ExUnit.Case, async: true

  alias Alavi.Profile
  alias Alavi.Profile.Identity

  @fixture Path.expand("../../../../contract/fixtures/identity-checks.v1.json", __DIR__)
  @profiles Path.expand("../../../../contract/profiles", __DIR__)

  setup do
    {:ok, profiles} = Profile.load_dir(@profiles)
    %{"format" => "identity-checks/1"} = fixture = @fixture |> File.read!() |> JSON.decode!()
    %{fixture: fixture, profiles: profiles}
  end

  test "each profile reads what the fixture lists, in order", ctx do
    for {name, reads} <- ctx.fixture["reads"] do
      listed =
        for {check, table, address, count} <- Identity.reads(ctx.profiles[name].identity),
            do: [Atom.to_string(check), Atom.to_string(table), address, count]

      assert listed == reads, name
    end
  end

  test "every case gets the fixture's verdict", ctx do
    for c <- ctx.fixture["cases"] do
      results =
        Map.new(c["results"], fn {check, r} -> {String.to_existing_atom(check), result(r)} end)

      verdict = Identity.verdict(ctx.profiles[c["profile"]].identity, results)
      assert wire(verdict) == c["verdict"], "#{c["profile"]}: #{c["why"]}"
    end
  end

  defp result(%{"words" => words}), do: {:ok, words}
  defp result(%{"exception" => code}), do: {:error, {:exception, code}}
  defp result(%{"error" => reason}), do: {:error, String.to_existing_atom(reason)}

  defp wire(:ok), do: "ok"
  defp wire({:mismatch, detail}) when is_binary(detail) and detail != "", do: "mismatch"
  defp wire({:error, {:exception, code}}), do: %{"read_failed" => %{"exception" => code}}
  defp wire({:error, reason}), do: %{"read_failed" => %{"error" => Atom.to_string(reason)}}
end
