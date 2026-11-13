defmodule Alavi.Buffer.Batch do
  alias Alavi.{Clock, Sink}

  @enforce_keys [:id, :clock, :events]
  defstruct @enforce_keys

  @type t :: %__MODULE__{id: String.t(), clock: Clock.status(), events: [Sink.event(), ...]}
end
