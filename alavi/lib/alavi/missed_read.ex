defmodule Alavi.MissedRead do
  @moduledoc """
  A register the poller was due to read and did not, with why. `attempts` 0
  means it was not tried: the meter or endpoint was already known unreachable
  this round, so the poller moved on to save bus time.
  """

  alias Alavi.{Decode, Modbus.Client, Reading}

  @enforce_keys [
    :endpoint,
    :unit_id,
    :meter_serial,
    :profile,
    :register_key,
    :timestamp,
    :reason,
    :attempts,
    :raw_words
  ]
  defstruct @enforce_keys

  @type reason ::
          Client.error()
          | {:unreachable, {:socket, term()}}
          | {:decode, Decode.error()}
          | {:profile_mismatch, String.t()}

  @type t :: %__MODULE__{
          endpoint: Reading.endpoint(),
          unit_id: 1..247,
          meter_serial: String.t(),
          profile: String.t(),
          register_key: String.t(),
          timestamp: DateTime.t(),
          reason: reason(),
          attempts: non_neg_integer(),
          raw_words: [0..0xFFFF] | nil
        }

  # contract: test/alavi/wire_test.exs "MissedRead.to_wire/1"
  @spec to_wire(t()) :: %{String.t() => term()}
  def to_wire(%__MODULE__{} = m) do
    {reason, code, detail} = reason(m.reason)

    %{
      "endpoint" => %{"host" => m.endpoint.host, "port" => m.endpoint.port},
      "unit_id" => m.unit_id,
      "meter_serial" => m.meter_serial,
      "profile" => m.profile,
      "register_key" => m.register_key,
      "timestamp" => DateTime.to_iso8601(m.timestamp),
      "reason" => reason,
      "exception_code" => code,
      "detail" => detail,
      "attempts" => m.attempts,
      "raw_words" => m.raw_words
    }
  end

  @plain [
    :timeout,
    :closed,
    :invalid_request,
    :unexpected_response,
    :malformed_response,
    :bad_crc,
    :malformed_frame
  ]

  defp reason({:exception, code}), do: {"exception", code, nil}
  defp reason({:socket, why}), do: {"socket", nil, detail(why)}
  defp reason({:unreachable, {:socket, why}}), do: {"unreachable", nil, detail(why)}
  defp reason({:decode, why}), do: {"decode", nil, Atom.to_string(why)}
  defp reason({:profile_mismatch, why}), do: {"profile_mismatch", nil, String.slice(why, 0, 200)}
  defp reason(plain) when plain in @plain, do: {Atom.to_string(plain), nil, nil}

  defp detail(why) when is_atom(why), do: Atom.to_string(why)
  defp detail(why), do: why |> inspect() |> String.slice(0, 200)
end
