defmodule Alavi.Reading do
  @moduledoc """
  One register read from one meter, as it leaves the poller. `meter_serial` and
  `product_code` are what the meter reported in the round the reading was
  taken in, never the config's. `raw_words` keeps what the meter sent, so a
  reading can be decoded again if its profile entry turns out to be wrong.
  """

  @enforce_keys [
    :endpoint,
    :unit_id,
    :meter_serial,
    :product_code,
    :profile,
    :register_key,
    :timestamp,
    :raw_words,
    :value,
    :unit
  ]
  defstruct @enforce_keys

  @type endpoint :: %{host: String.t(), port: :inet.port_number()}

  @typedoc "`timestamp` is the collector's UTC clock when the reply arrived."
  @type t :: %__MODULE__{
          endpoint: endpoint(),
          unit_id: 1..247,
          meter_serial: String.t(),
          product_code: String.t(),
          profile: String.t(),
          register_key: String.t(),
          timestamp: DateTime.t(),
          raw_words: [0..0xFFFF, ...],
          value: Decimal.t(),
          unit: String.t()
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
      "register_key" => r.register_key,
      "timestamp" => DateTime.to_iso8601(r.timestamp),
      "raw_words" => r.raw_words,
      "value" => Decimal.to_string(r.value, :normal),
      "unit" => r.unit
    }
  end
end
