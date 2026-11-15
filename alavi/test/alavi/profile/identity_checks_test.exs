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

      {outcome, observed} = Identity.verdict(ctx.profiles[c["profile"]].identity, results)
      label = "#{c["profile"]}: #{c["why"]}"
      assert wire(outcome) == c["verdict"], label

      assert %{"serial" => observed.serial, "product_code" => observed.product_code} ==
               c["observed"],
             label
    end
  end

  test "each profile's reads merge into the fixture's requests", ctx do
    for {name, requests} <- ctx.fixture["requests"] do
      made =
        for {table, address, count, reads} <- Identity.requests(ctx.profiles[name].identity),
            do: [
              Atom.to_string(table),
              address,
              count,
              for({c, _, _, _} <- reads, do: Atom.to_string(c))
            ]

      assert made == requests, name
    end
  end

  test "a merged reply gives each read the words it gives alone, and the same verdict", ctx do
    for c <- ctx.fixture["cases"] do
      identity = ctx.profiles[c["profile"]].identity

      alone =
        Map.new(c["results"], fn {check, r} -> {String.to_existing_atom(check), result(r)} end)

      merged =
        identity
        |> Identity.requests()
        |> Enum.map(&replied(&1, alone))
        |> Enum.reduce(&Map.merge/2)

      label = "#{c["profile"]}: #{c["why"]}"

      assert merged == alone, label
      assert Identity.verdict(identity, merged) == Identity.verdict(identity, alone), label
    end
  end

  # A meter's reply to `request`, its other registers 0xFFFF; or, where any of its
  # reads fails alone, those reads made alone, as the poller falls back to them.
  defp replied({_, start, count, reads} = request, alone) do
    if Enum.all?(reads, fn {check, _, _, _} -> match?({:ok, _}, alone[check]) end) do
      words =
        Enum.reduce(reads, List.duplicate(0xFFFF, count), fn {check, _, address, _}, words ->
          {:ok, own} = alone[check]
          splice(words, address - start, own)
        end)

      Identity.split(request, words)
    else
      Map.new(reads, fn {check, _, _, _} -> {check, alone[check]} end)
    end
  end

  defp splice(words, offset, own),
    do: Enum.take(words, offset) ++ own ++ Enum.drop(words, offset + length(own))

  defp result(%{"words" => words}), do: {:ok, words}
  defp result(%{"exception" => code}), do: {:error, {:exception, code}}
  defp result(%{"error" => reason}), do: {:error, String.to_existing_atom(reason)}

  defp wire(:ok), do: "ok"
  defp wire({:mismatch, detail}) when is_binary(detail) and detail != "", do: "mismatch"
  defp wire({:error, {:exception, code}}), do: %{"read_failed" => %{"exception" => code}}
  defp wire({:error, reason}), do: %{"read_failed" => %{"error" => Atom.to_string(reason)}}
end
