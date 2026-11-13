defmodule Alavi.Modbus.ReadResponsesTest do
  @moduledoc """
  `contract/fixtures/modbus-read-responses.v1.json`: what the collector makes of
  the bytes after a read, stepped as `Alavi.Modbus.Client` steps them.
  """
  use ExUnit.Case, async: true

  alias Alavi.Modbus.{Framing, PDU}

  @fixture Path.expand("../../../../contract/fixtures/modbus-read-responses.v1.json", __DIR__)

  test "every case gives the fixture's skips, result and rest" do
    %{"format" => "modbus-read-responses/1", "cases" => cases} =
      @fixture |> File.read!() |> JSON.decode!()

    for c <- cases do
      framing = String.to_existing_atom(c["framing"])
      e = c["expected"]
      table = String.to_existing_atom(e["table"])

      expected = %{
        transaction_id: e["transaction_id"],
        unit_id: e["unit_id"],
        function_code: PDU.function_code(table)
      }

      {skipped, result, rest} =
        step(framing, Base.decode16!(c["buffer"], case: :lower), expected, [])

      outcome = {skipped, wire(result, table, e["count"]), Base.encode16(rest, case: :lower)}
      assert outcome == {c["skipped"], c["result"], c["rest"]}, "#{c["framing"]}: #{c["why"]}"
    end
  end

  defp step(framing, buffer, expected, skipped) do
    case Framing.take_reply(framing, buffer, expected) do
      {:skip, why, rest} -> step(framing, rest, expected, skipped ++ [Atom.to_string(why)])
      {:ok, pdu, rest} -> {skipped, {:pdu, pdu}, rest}
      :incomplete -> {skipped, :incomplete, buffer}
      {:error, reason} -> {skipped, {:error, reason}, buffer}
    end
  end

  defp wire({:pdu, pdu}, table, count) do
    case PDU.parse_response(table, count, pdu) do
      {:ok, words} -> %{"words" => words}
      {:error, {:exception, code}} -> %{"exception" => code}
      {:error, reason} -> %{"error" => Atom.to_string(reason)}
    end
  end

  defp wire(:incomplete, _table, _count), do: "incomplete"
  defp wire({:error, reason}, _table, _count), do: %{"error" => Atom.to_string(reason)}
end
