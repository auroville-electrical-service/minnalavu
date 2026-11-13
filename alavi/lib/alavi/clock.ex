defmodule Alavi.Clock do
  @moduledoc """
  How far the collector's clock can be trusted, as a batch's `clock` reports it.

  It is captured when readings are recorded, not when they are sent: a batch
  sent after an NTP sync may hold readings taken weeks earlier on an unsynced
  clock.
  """

  @type source :: :ntp | :rtc | :unsynced

  @type status :: %{source: source(), last_sync_at: DateTime.t() | nil}

  @typedoc "Returns the current status; called once per `Alavi.Buffer.record/2`."
  @type status_fun :: (-> status())

  @doc """
  Also the status where the collector cannot tell, even if the host OS syncs its
  clock.

      iex> Alavi.Clock.unsynced()
      %{source: :unsynced, last_sync_at: nil}
  """
  @spec unsynced() :: status()
  def unsynced, do: %{source: :unsynced, last_sync_at: nil}

  @doc """
      iex> Alavi.Clock.to_wire(%{source: :ntp, last_sync_at: ~U[2026-11-01 00:00:00Z]})
      %{"source" => "ntp", "last_sync_at" => "2026-11-01T00:00:00Z"}
  """
  @spec to_wire(status()) :: %{String.t() => String.t() | nil}
  def to_wire(%{source: source, last_sync_at: at}),
    do: %{"source" => Atom.to_string(source), "last_sync_at" => at && DateTime.to_iso8601(at)}
end
