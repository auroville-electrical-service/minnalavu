defmodule Alavi.Config.Digest do
  @moduledoc """
  A polling config's digest, as `contract/fixtures/config.v1.digests.json`
  defines it: SHA-256, in lowercase hex, of the UTF-8 bytes of the decoded
  document's canonical encoding (RFC 8785). Computed from the document, never
  from the bytes it arrived as: the server's text is not canonical.
  """

  @type t :: String.t()

  # contract: test/alavi/config/digest_test.exs "digest/1"
  @spec digest(term()) :: {:ok, t()} | {:error, String.t()}
  def digest(document) do
    with {:ok, text} <- canonical(document),
         do: {:ok, :sha256 |> :crypto.hash(text) |> Base.encode16(case: :lower)}
  end

  # contract: test/alavi/config/digest_test.exs "canonical/1"
  @doc "Only what a decoded config holds has a canonical form here: no number but an integer."
  @spec canonical(term()) :: {:ok, String.t()} | {:error, String.t()}
  def canonical(document) do
    case unencodable(document) do
      nil -> {:ok, document |> encode() |> IO.iodata_to_binary()}
      value -> {:error, "the config holds #{inspect(value)}, which has no canonical form here"}
    end
  end

  defp unencodable(map) when is_map(map) do
    Enum.find_value(map, fn
      {key, value} when is_binary(key) -> unencodable(value)
      {key, _value} -> key
    end)
  end

  defp unencodable(list) when is_list(list), do: Enum.find_value(list, &unencodable/1)
  defp unencodable(value) when is_binary(value) or is_integer(value) or is_boolean(value), do: nil
  defp unencodable(nil), do: nil
  defp unencodable(value), do: value

  defp encode(map) when is_map(map) do
    members =
      map
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map(fn {key, value} -> [string(key), ?:, encode(value)] end)

    [?{, Enum.intersperse(members, ?,), ?}]
  end

  defp encode(list) when is_list(list),
    do: [?[, list |> Enum.map(&encode/1) |> Enum.intersperse(?,), ?]]

  defp encode(string) when is_binary(string), do: string(string)
  defp encode(integer) when is_integer(integer), do: Integer.to_string(integer)
  defp encode(true), do: "true"
  defp encode(false), do: "false"
  defp encode(nil), do: "null"

  defp string(string), do: [?", escape(string, []), ?"]

  defp escape(<<>>, acc), do: Enum.reverse(acc)
  defp escape(<<?", rest::binary>>, acc), do: escape(rest, [~S(\") | acc])
  defp escape(<<?\\, rest::binary>>, acc), do: escape(rest, [~S(\\) | acc])
  defp escape(<<?\b, rest::binary>>, acc), do: escape(rest, [~S(\b) | acc])
  defp escape(<<?\t, rest::binary>>, acc), do: escape(rest, [~S(\t) | acc])
  defp escape(<<?\n, rest::binary>>, acc), do: escape(rest, [~S(\n) | acc])
  defp escape(<<?\f, rest::binary>>, acc), do: escape(rest, [~S(\f) | acc])
  defp escape(<<?\r, rest::binary>>, acc), do: escape(rest, [~S(\r) | acc])
  defp escape(<<c, rest::binary>>, acc) when c < 0x20, do: escape(rest, [control(c) | acc])
  defp escape(<<c, rest::binary>>, acc), do: escape(rest, [c | acc])

  defp control(c),
    do: ["\\u00", c |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(2, "0")]
end
