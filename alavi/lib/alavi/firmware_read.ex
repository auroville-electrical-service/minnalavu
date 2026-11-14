defmodule Alavi.FirmwareRead do
  @moduledoc """
  A meter's software and firmware names, read in a round that also read its
  serial and product code. A name is nil where the meter did not give it: it
  answered blank or with text that is not printable, or with exception 02 (no
  such register). Informational only: nothing about a reading depends on it.
  """

  alias Alavi.Reading

  @enforce_keys [
    :endpoint,
    :unit_id,
    :meter_serial,
    :product_code,
    :timestamp,
    :software,
    :firmware_1,
    :firmware_2,
    :modbus_version
  ]
  defstruct @enforce_keys

  @type name :: String.t() | nil

  @typedoc "`timestamp` is the collector's UTC clock when the names were read."
  @type t :: %__MODULE__{
          endpoint: Reading.endpoint(),
          unit_id: 1..247,
          meter_serial: String.t(),
          product_code: String.t(),
          timestamp: DateTime.t(),
          software: name(),
          firmware_1: name(),
          firmware_2: name(),
          modbus_version: name()
        }

  # contract: test/alavi/wire_test.exs "FirmwareRead.to_wire/1"
  @spec to_wire(t()) :: %{String.t() => term()}
  def to_wire(%__MODULE__{} = f) do
    %{
      "endpoint" => %{"host" => f.endpoint.host, "port" => f.endpoint.port},
      "unit_id" => f.unit_id,
      "meter_serial" => f.meter_serial,
      "product_code" => f.product_code,
      "timestamp" => DateTime.to_iso8601(f.timestamp),
      "software" => f.software,
      "firmware_1" => f.firmware_1,
      "firmware_2" => f.firmware_2,
      "modbus_version" => f.modbus_version
    }
  end
end
