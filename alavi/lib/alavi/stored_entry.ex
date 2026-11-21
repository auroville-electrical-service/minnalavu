defmodule Alavi.StoredEntry do
  @moduledoc """
  One quantity of one entry a meter stores (a billing history, a daily
  snapshot, a load-survey interval), as a copy read it. Its identity is the
  meter's own stamp, `meter_time`, never `slot`, the selector value it was
  read at. `value` is decoded under `profile` at `profile_version`, whose
  stored section gives `register_key` its unit and kind; `interval_s` is a
  load-survey entry's length, nil on any other. `request_id` names the fill
  request it was copied for, nil for a nightly copy.
  """

  alias Alavi.{Profile, Reading}

  @enforce_keys [
    :endpoint,
    :unit_id,
    :meter_serial,
    :product_code,
    :profile,
    :profile_version,
    :store,
    :meter_time,
    :interval_s,
    :register_key,
    :value,
    :slot,
    :copied_at,
    :request_id
  ]
  defstruct @enforce_keys

  @type store :: :history | :snapshot | :load_survey

  @typedoc "`copied_at` is the collector's UTC clock when the reply arrived."
  @type t :: %__MODULE__{
          endpoint: Reading.endpoint(),
          unit_id: 1..247,
          meter_serial: String.t(),
          product_code: String.t(),
          profile: String.t(),
          profile_version: Profile.version(),
          store: store(),
          meter_time: NaiveDateTime.t(),
          interval_s: pos_integer() | nil,
          register_key: String.t(),
          value: Decimal.t(),
          slot: 0..0xFFFF,
          copied_at: DateTime.t(),
          request_id: String.t() | nil
        }

  # contract: test/alavi/wire_test.exs "batch/4"
  @spec to_wire(t()) :: %{String.t() => term()}
  def to_wire(%__MODULE__{} = e) do
    %{
      "endpoint" => %{"host" => e.endpoint.host, "port" => e.endpoint.port},
      "unit_id" => e.unit_id,
      "meter_serial" => e.meter_serial,
      "product_code" => e.product_code,
      "profile" => e.profile,
      "profile_version" => e.profile_version,
      "store" => Atom.to_string(e.store),
      "meter_time" => NaiveDateTime.to_iso8601(e.meter_time),
      "register_key" => e.register_key,
      "value" => Decimal.to_string(e.value, :normal),
      "slot" => e.slot,
      "copied_at" => DateTime.to_iso8601(e.copied_at)
    }
    |> interval(e.interval_s)
    |> request(e.request_id)
  end

  defp interval(wire, nil), do: wire
  defp interval(wire, seconds), do: Map.put(wire, "interval_s", seconds)

  defp request(wire, nil), do: wire
  defp request(wire, id), do: Map.put(wire, "request_id", id)
end
