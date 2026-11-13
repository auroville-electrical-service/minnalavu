defmodule Alavi.Modbus.CRC do
  @moduledoc """
  CRC-16/MODBUS (polynomial 0xA001 reflected, initial 0xFFFF), as used by RTU framing.

      iex> Alavi.Modbus.CRC.checksum(<<0x01, 0x04, 0x00, 0x00, 0x00, 0x02>>)
      0xCB71
  """

  import Bitwise

  @doc "On the wire the CRC is sent low byte first."
  @spec checksum(binary()) :: 0..0xFFFF
  def checksum(data) do
    for <<byte <- data>>, reduce: 0xFFFF do
      crc -> Enum.reduce(1..8, bxor(crc, byte), fn _, acc -> shift(acc) end)
    end
  end

  @spec append(binary()) :: binary()
  def append(data), do: data <> <<checksum(data)::little-16>>

  defp shift(crc) when (crc &&& 1) == 1, do: bxor(crc >>> 1, 0xA001)
  defp shift(crc), do: crc >>> 1
end
