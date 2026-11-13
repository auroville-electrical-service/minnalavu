defmodule Alavi.Reader do
  alias Alavi.{Decode, Modbus.Client, Profile.Register}

  @type reading :: %{words: [0..0xFFFF], value: Decimal.t()}

  @spec read(Client.t(), 1..247, Register.t()) ::
          {:ok, reading(), Client.t()}
          | {:error, Client.error() | {Decode.error(), [0..0xFFFF]}, Client.t()}
  def read(client, unit_id, %Register{} = register) do
    count = Register.word_count(register)

    with {:ok, words, client} <-
           Client.read(client, unit_id, register.table, register.address, count) do
      case Decode.value(register, words) do
        {:ok, value} -> {:ok, %{words: words, value: value}, client}
        {:error, reason} -> {:error, {reason, words}, client}
      end
    end
  end
end
