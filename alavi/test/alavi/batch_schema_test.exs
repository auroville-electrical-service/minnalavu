defmodule Alavi.BatchSchemaTest do
  use ExUnit.Case, async: true

  @contract Path.expand("../../../contract", __DIR__)

  # The cases are shared with the server's SQL tests, so both sides hold
  # batches to the same rules.
  @cases @contract |> Path.join("fixtures/batch.v1.cases.json") |> File.read!() |> JSON.decode!()

  setup_all do
    schema = read_json("schema/batch.v1.schema.json")

    {:ok,
     root: JSV.build!(schema, formats: true), fixture: read_json("fixtures/batch.v1.basic.json")}
  end

  test "the contract fixture validates against the batch schema", ctx do
    assert {:ok, _} = JSV.validate(ctx.fixture, ctx.root)
  end

  for %{"name" => name} = rule <- @cases["cases"] do
    test "rejects #{name}", ctx do
      batch = change(ctx.fixture, unquote(Macro.escape(rule)))
      assert {:error, _} = JSV.validate(batch, ctx.root)
    end
  end

  for %{"name" => name, "changes" => changes} <- @cases["valid"] do
    test "accepts #{name}", ctx do
      batch = Enum.reduce(unquote(Macro.escape(changes)), ctx.fixture, &change(&2, &1))
      assert {:ok, _} = JSV.validate(batch, ctx.root)
    end
  end

  defp change(batch, %{"path" => path, "delete" => true}),
    do: batch |> pop_in(access(path)) |> elem(1)

  defp change(batch, %{"path" => path, "value" => value}), do: put_in(batch, access(path), value)

  defp access(path),
    do:
      Enum.map(path, fn
        i when is_integer(i) -> Access.at(i)
        key -> key
      end)

  defp read_json(path), do: @contract |> Path.join(path) |> File.read!() |> JSON.decode!()
end
