defmodule Alavi.Modbus.PDU do
  @moduledoc """
  Only function codes 03 and 04 exist here. There is deliberately no way to
  build a write request: this system never writes to meters.
  """

  @enforce_keys [:bytes]
  defstruct [:bytes]

  @typedoc "A read request PDU, built only by `read_request/3`."
  @opaque t :: %__MODULE__{bytes: binary()}

  @typedoc "Register table: `:holding` is function code 03, `:input` is 04."
  @type table :: :holding | :input
  @type word :: 0..0xFFFF
  @type exception_code :: 1..255
  @type error :: {:exception, exception_code()} | :malformed_response

  @max_count 125

  # contract: test/alavi/modbus/read_only_test.exs "read_request/3"
  @doc """
  `address` is zero-based.

      iex> {:ok, request} = Alavi.Modbus.PDU.read_request(:input, 9000, 2)
      iex> Alavi.Modbus.PDU.bytes(request)
      <<4, 0x23, 0x28, 0, 2>>
  """
  @spec read_request(table(), non_neg_integer(), pos_integer()) ::
          {:ok, t()} | {:error, :invalid_request}
  def read_request(table, address, count)
      when table in [:holding, :input] and address in 0..0xFFFF and count in 1..@max_count and
             address + count <= 0x10000 do
    {:ok, %__MODULE__{bytes: <<function_code(table), address::16, count::16>>}}
  end

  def read_request(_table, _address, _count), do: {:error, :invalid_request}

  @spec bytes(t()) :: binary()
  def bytes(%__MODULE__{bytes: bytes}), do: bytes

  @doc """
      iex> Alavi.Modbus.PDU.parse_response(:input, 2, <<4, 4, 0x47, 0xF1, 0x20, 0x00>>)
      {:ok, [0x47F1, 0x2000]}

      iex> Alavi.Modbus.PDU.parse_response(:input, 2, <<0x84, 2>>)
      {:error, {:exception, 2}}
  """
  @spec parse_response(table(), pos_integer(), binary()) :: {:ok, [word()]} | {:error, error()}
  def parse_response(table, count, pdu) do
    fc = function_code(table)
    exception_fc = fc + 0x80
    byte_count = count * 2

    case pdu do
      <<^fc, ^byte_count, data::binary-size(^byte_count)>> -> {:ok, words(data)}
      <<^exception_fc, code>> when code > 0 -> {:error, {:exception, code}}
      _ -> {:error, :malformed_response}
    end
  end

  @spec function_code(table()) :: 3 | 4
  def function_code(:holding), do: 3
  def function_code(:input), do: 4

  defp words(data), do: for(<<word::16 <- data>>, do: word)
end
