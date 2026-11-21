defmodule Alavi.LatencyDay do
  @moduledoc """
  One meter's request latency over the part of a UTC date one poller ran, as
  `Alavi.Poller.Latency` counted it: sent when the date ends and when the
  poller stops. Counts only, never percentiles (the store computes those).
  `poller_started_at` sets apart a restart's part of a day from the part
  before it. `late` counts the replies that came too late for their request.
  """

  alias Alavi.Poller.Latency
  alias Alavi.Reading

  @enforce_keys [
    :endpoint,
    :unit_id,
    :date,
    :poller_started_at,
    :buckets_version,
    :retries,
    :timeouts,
    :max_ms,
    :buckets,
    :late
  ]
  defstruct @enforce_keys

  @typedoc """
  `buckets`: the answers in each bucket of version `buckets_version`'s
  bounds, every bucket given. `max_ms` is nil when nothing answered.
  """
  @type t :: %__MODULE__{
          endpoint: Reading.endpoint(),
          unit_id: 1..247,
          date: Date.t(),
          poller_started_at: DateTime.t(),
          buckets_version: pos_integer(),
          retries: non_neg_integer(),
          timeouts: non_neg_integer(),
          max_ms: non_neg_integer() | nil,
          buckets: [non_neg_integer(), ...],
          late: Latency.late()
        }

  @spec new(Reading.endpoint(), 1..247, DateTime.t(), Date.t(), Latency.counts()) :: t()
  def new(endpoint, unit_id, started_at, date, counts) do
    %__MODULE__{
      endpoint: endpoint,
      unit_id: unit_id,
      date: date,
      poller_started_at: started_at,
      buckets_version: Latency.bucket_version(),
      retries: counts.retries,
      timeouts: counts.timeouts,
      max_ms: counts.max,
      buckets: counts.buckets,
      late: counts.late
    }
  end

  # contract: test/alavi/buffer_test.exs "record/2"
  @doc "The earliest time it counts: its date's start, or the poller's, if later."
  @spec since(t()) :: DateTime.t()
  def since(%__MODULE__{date: date, poller_started_at: started}),
    do: Enum.max([DateTime.new!(date, ~T[00:00:00], "Etc/UTC"), started], DateTime)

  # contract: test/alavi/wire_test.exs "LatencyDay.to_wire/1"
  @spec to_wire(t()) :: %{String.t() => term()}
  def to_wire(%__MODULE__{} = l) do
    %{
      "endpoint" => %{"host" => l.endpoint.host, "port" => l.endpoint.port},
      "unit_id" => l.unit_id,
      "date" => Date.to_iso8601(l.date),
      "poller_started_at" => DateTime.to_iso8601(l.poller_started_at),
      "buckets_version" => l.buckets_version,
      "retries" => l.retries,
      "timeouts" => l.timeouts,
      "max_ms" => l.max_ms,
      "buckets" => l.buckets,
      "late" => %{
        "data" => l.late.data,
        "exceptions" =>
          Map.new(l.late.exceptions, fn {code, n} -> {Integer.to_string(code), n} end)
      }
    }
  end
end
