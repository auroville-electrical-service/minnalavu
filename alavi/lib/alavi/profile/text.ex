defmodule Alavi.Profile.Text do
  @moduledoc """
  Text a meter reports in registers: ASCII, two bytes per register, high byte
  first. Shared by the identity check and the firmware names, so both read text
  the same way.
  """

  @doc """
  The bytes of `words`, without trailing NULs and then without surrounding
  ASCII whitespace; matched bytewise, so `kai_alavi` trims exactly the same
  bytes. A NUL inside is kept: it is not padding.
  """
  @spec trimmed([0..0xFFFF]) :: binary()
  def trimmed(words) do
    unpadded = words |> Enum.map_join(&<<&1::16>>) |> String.trim_trailing(<<0>>)
    [text] = Regex.run(~r/\A[\t-\r ]*(.*?)[\t-\r ]*\z/s, unpadded, capture: :all_but_first)
    text
  end

  @doc "`text` if it is non-empty printable ASCII, else nil."
  @spec printable(binary()) :: String.t() | nil
  def printable(text), do: if(text =~ ~r/\A[\x20-\x7E]+\z/, do: text)
end
