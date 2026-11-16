defmodule Alavi.MeterClockRead do
  @moduledoc """
  A read of a meter's own clock, decoded under `profile` at `profile_version`
  (its `meter_clock`), and the collector's clock when the reply arrived. Raw
  evidence: no offset is computed here.
  """

  alias Alavi.{Profile, Reading}

  @enforce_keys [
    :endpoint,
    :unit_id,
    :meter_serial,
    :profile,
    :profile_version,
    :meter_time,
    :collector_at
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          endpoint: Reading.endpoint(),
          unit_id: 1..247,
          meter_serial: String.t(),
          profile: String.t(),
          profile_version: Profile.version(),
          meter_time: NaiveDateTime.t(),
          collector_at: DateTime.t()
        }

  # contract: test/alavi/wire_test.exs "batch/4"
  @spec to_wire(t()) :: %{String.t() => term()}
  def to_wire(%__MODULE__{} = r) do
    %{
      "endpoint" => %{"host" => r.endpoint.host, "port" => r.endpoint.port},
      "unit_id" => r.unit_id,
      "meter_serial" => r.meter_serial,
      "profile" => r.profile,
      "profile_version" => r.profile_version,
      "meter_time" => NaiveDateTime.to_iso8601(r.meter_time),
      "collector_at" => DateTime.to_iso8601(r.collector_at)
    }
  end
end
