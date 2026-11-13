defmodule Alavi.Profile.Identity do
  @moduledoc """
  What a meter must report before its profile's registers are trusted, parsed
  from a profile's `identity` section. Both checks are optional per profile.
  Pure: `reads/1` lists what to read, `verdict/2` judges what came back.
  """

  alias Alavi.Config.Fields
  alias Alavi.Modbus.{Client, PDU}
  alias Alavi.Profile.Register

  @enforce_keys [:product_code, :energy_unit]
  defstruct @enforce_keys

  @type product_code :: %{
          table: PDU.table(),
          address: 0..0xFFFF,
          count: 1..125,
          accept: [String.t(), ...],
          source: Register.source()
        }
  @typedoc """
  With `absent_ok`, exception 02 (illegal address) means the meter has no unit
  setting and reports the profile's unit, as older Elite 440 firmware does.
  """
  @type energy_unit :: %{
          table: PDU.table(),
          address: 0..0xFFFF,
          part: :high_byte | :word,
          expect: 0..0xFFFF,
          absent_ok: boolean(),
          source: Register.source()
        }
  @type t :: %__MODULE__{product_code: product_code() | nil, energy_unit: energy_unit() | nil}

  @type check :: :product_code | :energy_unit
  @type read :: {check(), PDU.table(), 0..0xFFFF, pos_integer()}
  @type result :: {:ok, [0..0xFFFF]} | {:error, Client.error()}
  @type verdict :: :ok | {:mismatch, String.t()} | {:error, Client.error()}

  @tables %{"holding" => :holding, "input" => :input}
  @parts %{"high_byte" => :high_byte, "word" => :word}
  @illegal_address {:exception, 2}

  # contract: test/alavi/profile/identity_test.exs "parse/1"
  @spec parse(term()) :: {:ok, t()} | {:error, String.t()}
  def parse(%{} = json) do
    with :ok <- Fields.only(json, ["product_code", "energy_unit"]),
         {:ok, product_code} <- optional(json, "product_code", &product_code/1),
         {:ok, energy_unit} <- optional(json, "energy_unit", &energy_unit/1) do
      {:ok, %__MODULE__{product_code: product_code, energy_unit: energy_unit}}
    end
  end

  def parse(_json), do: {:error, "identity must be an object"}

  @spec sources(t()) :: [Register.source()]
  def sources(%__MODULE__{product_code: product, energy_unit: unit}),
    do: for(%{source: id} <- [product, unit], do: id)

  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{product_code: nil, energy_unit: nil}), do: true
  def empty?(%__MODULE__{}), do: false

  # contract: test/alavi/profile/identity_test.exs "reads/1"
  @spec reads(t()) :: [read()]
  def reads(%__MODULE__{} = identity) do
    for check <- [:product_code, :energy_unit],
        spec = Map.fetch!(identity, check),
        spec != nil,
        do: {check, spec.table, spec.address, words(check, spec)}
  end

  # contract: test/alavi/profile/identity_test.exs "verdict/2"
  @spec verdict(t(), %{check() => result()}) :: verdict()
  def verdict(%__MODULE__{} = identity, results) do
    Enum.reduce_while(reads(identity), :ok, fn {check, _, _, _}, :ok ->
      case judge(check, Map.fetch!(identity, check), Map.fetch!(results, check)) do
        :ok -> {:cont, :ok}
        failed -> {:halt, failed}
      end
    end)
  end

  defp words(:product_code, %{count: count}), do: count
  defp words(:energy_unit, _spec), do: 1

  defp judge(:product_code, spec, {:ok, words}) do
    code = ascii(words)

    if code in spec.accept,
      do: :ok,
      else:
        {:mismatch,
         "product code #{inspect(code)}, expected one of #{Enum.join(spec.accept, ", ")}"}
  end

  defp judge(:energy_unit, %{absent_ok: true}, {:error, @illegal_address}), do: :ok

  defp judge(:energy_unit, spec, {:ok, [word]}) do
    code = part(spec.part, word)

    if code == spec.expect,
      do: :ok,
      else:
        {:mismatch,
         "energy unit code #{code} at #{spec.table} #{spec.address}, expected #{spec.expect}"}
  end

  defp judge(_check, _spec, {:error, error}), do: {:error, error}

  defp part(:high_byte, word), do: Bitwise.bsr(word, 8)
  defp part(:word, word), do: word

  defp ascii(words) do
    words
    |> Enum.map_join(&<<&1::16>>)
    |> String.trim_trailing(<<0>>)
    |> String.trim()
  end

  defp optional(json, field, parse) do
    case Map.fetch(json, field) do
      :error -> {:ok, nil}
      {:ok, %{} = entry} -> prefixed(field, parse.(entry))
      {:ok, _} -> {:error, "identity.#{field} must be an object"}
    end
  end

  defp prefixed(_field, {:ok, _} = ok), do: ok
  defp prefixed(field, {:error, reason}), do: {:error, "identity.#{field}: #{reason}"}

  defp product_code(json) do
    with :ok <- Fields.only(json, ["table", "address", "count", "accept", "source"]),
         {:ok, table} <- Fields.lookup(json, "table", @tables),
         {:ok, address} <- Fields.integer(json, "address", 0..0xFFFF),
         {:ok, count} <- Fields.integer(json, "count", 1..125),
         {:ok, accept} <- accept(json),
         {:ok, source} <- Register.parse_source(json["source"]) do
      {:ok, %{table: table, address: address, count: count, accept: accept, source: source}}
    end
  end

  defp energy_unit(json) do
    with :ok <-
           Fields.only(json, ["table", "address", "part", "expect", "absent_ok", "source"]),
         {:ok, table} <- Fields.lookup(json, "table", @tables),
         {:ok, address} <- Fields.integer(json, "address", 0..0xFFFF),
         {:ok, part} <- Fields.lookup(json, "part", @parts),
         {:ok, expect} <- Fields.integer(json, "expect", 0..0xFFFF),
         {:ok, absent_ok} <- Fields.boolean(json, "absent_ok"),
         {:ok, source} <- Register.parse_source(json["source"]) do
      {:ok,
       %{
         table: table,
         address: address,
         part: part,
         expect: expect,
         absent_ok: absent_ok,
         source: source
       }}
    end
  end

  defp accept(%{"accept" => [_ | _] = codes}) do
    if Enum.all?(codes, &(is_binary(&1) and &1 != "")),
      do: {:ok, codes},
      else: {:error, "accept must list non-empty strings"}
  end

  defp accept(_json), do: {:error, "accept must be a non-empty list"}
end
