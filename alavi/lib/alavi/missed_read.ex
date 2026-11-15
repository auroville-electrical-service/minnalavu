defmodule Alavi.MissedRead do
  @moduledoc """
  A register the poller was due to read and did not, with why. `meter_serial`
  is the serial the meter reported that round, or nil when none was read.
  `attempts` 0 means it was not tried: the meter or endpoint was already known
  unreachable, or did not match its profile, this round. `request_id` is the
  request a read on demand was made for, or nil. `raw_words` are the words of
  a `decode` miss, which no value names, and nil otherwise.
  """

  alias Alavi.{Decode, Modbus.Client, Profile, Reading}

  @enforce_keys [
    :endpoint,
    :unit_id,
    :meter_serial,
    :profile,
    :profile_version,
    :register_key,
    :timestamp,
    :reason,
    :attempts,
    :raw_words
  ]
  defstruct @enforce_keys ++ [request_id: nil]

  @type reason ::
          Client.error()
          | {:unreachable, {:socket, term()}}
          | {:decode, Decode.error()}
          | {:profile_mismatch, String.t()}

  @type t :: %__MODULE__{
          endpoint: Reading.endpoint(),
          unit_id: 1..247,
          meter_serial: String.t() | nil,
          profile: String.t(),
          profile_version: Profile.version(),
          register_key: String.t(),
          timestamp: DateTime.t(),
          reason: reason(),
          attempts: non_neg_integer(),
          raw_words: [0..0xFFFF] | nil,
          request_id: String.t() | nil
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
      "profile_version" => m.profile_version,
      "register_key" => m.register_key,
      "timestamp" => DateTime.to_iso8601(m.timestamp),
      "reason" => reason,
      "exception_code" => code,
      "detail" => detail,
      "attempts" => m.attempts,
      "raw_words" => m.raw_words
    }
    |> Reading.request(m.request_id)
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
