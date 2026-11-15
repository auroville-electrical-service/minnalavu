defmodule Alavi.ConfigCases do
  @moduledoc "contract/fixtures' polling config and the changes it must refuse or accept."

  @contract Path.expand("../../../contract", __DIR__)
  @path Path.join(@contract, "fixtures/config.v1.cases.json")
  @external_resource @path
  @cases @path |> File.read!() |> JSON.decode!()

  @spec read_json(Path.t()) :: term()
  def read_json(path), do: @contract |> Path.join(path) |> File.read!() |> JSON.decode!()

  @spec basic() :: map()
  def basic, do: read_json("fixtures/config.v1.basic.json")

  @doc "The cases `side` must refuse."
  @spec refused(String.t()) :: [map()]
  def refused(side), do: Enum.filter(@cases["cases"], &(side in &1["by"]))

  @doc "The valid changes `side` must accept."
  @spec accepted(String.t()) :: [map()]
  def accepted(side), do: Enum.filter(@cases["valid"], &(side in &1["by"]))

  @doc "Set `value` at `path`, or remove the field there when `delete` is true."
  @spec change(map(), map()) :: map()
  def change(config, %{"path" => path, "delete" => true}),
    do: config |> pop_in(access(path)) |> elem(1)

  def change(config, %{"path" => path, "value" => value}), do: put_in(config, access(path), value)

  defp access(path),
    do:
      Enum.map(path, fn
        i when is_integer(i) -> Access.at(i)
        key -> key
      end)
end
