defmodule Alavi.Config.Schema do
  @moduledoc false
  # contract/config's schema, read when alavi compiles: the parser takes its
  # fields, ranges and patterns from here, so it cannot drift from the
  # contract the registry is tested against.

  @path Path.expand("../../../../contract/config/config.v1.schema.json", __DIR__)
  @external_resource @path
  @schema @path |> File.read!() |> JSON.decode!()

  # A path names properties from the document's root, stepping through arrays
  # into their items: ["endpoints", "meters", "unit_id"].

  @spec fields([String.t()]) :: [String.t()]
  def fields(path), do: path |> at() |> object() |> Map.fetch!("properties") |> Map.keys()

  @spec range([String.t()]) :: Range.t()
  def range(path) do
    %{"type" => "integer", "minimum" => min, "maximum" => max} = at(path)
    min..max//1
  end

  @spec pattern([String.t()]) :: String.t()
  def pattern(path) do
    %{"type" => "string", "pattern" => pattern} = at(path)
    pattern
  end

  defp at(path) do
    path
    |> Enum.reduce(@schema, &(&2 |> object() |> Map.fetch!("properties") |> Map.fetch!(&1)))
    |> resolve()
  end

  defp object(node) do
    case resolve(node) do
      %{"type" => "array", "items" => items} -> resolve(items)
      %{"type" => "object"} = object -> object
    end
  end

  defp resolve(%{"$ref" => "#/" <> ref} = node),
    do: @schema |> get_in(String.split(ref, "/")) |> Map.merge(Map.delete(node, "$ref"))

  defp resolve(node), do: node
end
