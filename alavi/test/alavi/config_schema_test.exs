defmodule Alavi.ConfigSchemaTest do
  use ExUnit.Case, async: true

  import Alavi.ConfigCases

  # The cases are shared with the parser's tests and the registry's SQL tests,
  # so the schema, the collector and the registry hold a config to one set of
  # rules.

  setup_all do
    {:ok, root: JSV.build!(read_json("config/config.v1.schema.json"), formats: true)}
  end

  test "the contract fixture validates against the config schema", ctx do
    assert {:ok, _} = JSV.validate(basic(), ctx.root)
  end

  for %{"name" => name} = rule <- refused("schema") do
    test "rejects #{name}", ctx do
      assert {:error, _} = JSV.validate(change(basic(), unquote(Macro.escape(rule))), ctx.root)
    end
  end

  for %{"name" => name, "changes" => changes} <- accepted("schema") do
    test "accepts #{name}", ctx do
      config = Enum.reduce(unquote(Macro.escape(changes)), basic(), &change(&2, &1))
      assert {:ok, _} = JSV.validate(config, ctx.root)
    end
  end
end
