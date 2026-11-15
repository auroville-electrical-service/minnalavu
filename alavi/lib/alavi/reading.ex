defmodule Alavi.Reading do
  @moduledoc """
  One register read from one meter, as it leaves the poller. `meter_serial` and
  `product_code` are what the meter reported in the round the reading was
  taken in, never the config's. `value` is decoded under `profile` at
  `profile_version`, whose entry for `register_key` gives its unit and kind;
  for a float it is lossless, so the meter's words are recoverable from it and
  that entry. `request_id` is the request a read on demand was made for, or nil.
  """

  alias Alavi.Profile

  @enforce_keys [
    :endpoint,
    :unit_id,
    :meter_serial,
    :product_code,
    :profile,
    :profile_version,
    :register_key,
    :timestamp,
    :value
  ]
  defstruct @enforce_keys ++ [request_id: nil]

  @type endpoint :: %{host: String.t(), port: :inet.port_number()}

  @typedoc "`timestamp` is the collector's UTC clock when the reply arrived."
  @type t :: %__MODULE__{
          endpoint: endpoint(),
          unit_id: 1..247,
          meter_serial: String.t(),
          product_code: String.t(),
          profile: String.t(),
          profile_version: Profile.version(),
          register_key: String.t(),
          timestamp: DateTime.t(),
          value: Decimal.t(),
          request_id: String.t() | nil
        }

  # contract: test/alavi/wire_test.exs "Reading.to_wire/1"
  @spec to_wire(t()) :: %{String.t() => term()}
  def to_wire(%__MODULE__{} = r) do
    %{
      "endpoint" => %{"host" => r.endpoint.host, "port" => r.endpoint.port},
      "unit_id" => r.unit_id,
      "meter_serial" => r.meter_serial,
      "product_code" => r.product_code,
      "profile" => r.profile,
      "profile_version" => r.profile_version,
      "register_key" => r.register_key,
      "timestamp" => DateTime.to_iso8601(r.timestamp),
      "value" => Decimal.to_string(r.value, :normal)
    }
    |> request(r.request_id)
  end

  # contract: test/alavi/wire_test.exs "Reading.to_wire/1"
  @doc "`request_id` is on the wire only when set: the schema refuses null."
  @spec request(map(), String.t() | nil) :: map()
  def request(wire, nil), do: wire
  def request(wire, id), do: Map.put(wire, "request_id", id)
end
