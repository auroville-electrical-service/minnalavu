defmodule Alavi.FillResult do
  @moduledoc """
  A fill request's copy of one meter's store, finished: what of the range
  the meter no longer held. `gone_before` is the stamp of its oldest entry
  when that falls inside the range, the range's end when it holds none of
  the range, and nil when it holds entries from the range's start or older.
  """

  alias Alavi.Reading

  @enforce_keys [
    :request_id,
    :endpoint,
    :unit_id,
    :meter_serial,
    :store,
    :gone_before,
    :finished_at
  ]
  defstruct @enforce_keys

  @typedoc "`meter_serial` is the serial the meter reported in the visit; `finished_at` is the collector's UTC clock."
  @type t :: %__MODULE__{
          request_id: String.t(),
          endpoint: Reading.endpoint(),
          unit_id: 1..247,
          meter_serial: String.t(),
          store: :history | :snapshot | :load_survey,
          gone_before: NaiveDateTime.t() | nil,
          finished_at: DateTime.t()
        }

  # contract: test/alavi/wire_test.exs "batch/4"
  @spec to_wire(t()) :: %{String.t() => term()}
  def to_wire(%__MODULE__{} = r) do
    %{
      "request_id" => r.request_id,
      "endpoint" => %{"host" => r.endpoint.host, "port" => r.endpoint.port},
      "unit_id" => r.unit_id,
      "meter_serial" => r.meter_serial,
      "store" => Atom.to_string(r.store),
      "gone_before" => r.gone_before && NaiveDateTime.to_iso8601(r.gone_before),
      "finished_at" => DateTime.to_iso8601(r.finished_at)
    }
  end
end
