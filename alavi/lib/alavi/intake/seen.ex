defmodule Alavi.Intake.Seen do
  @moduledoc """
  The request IDs this collector has run or refused, so that it runs each
  once although every ingest answer lists a request until its first reading
  or missed read arrives. Pure; held in memory only, so a restart forgets it,
  and a request still pending then is run again.

  An ID is kept, by the collector's monotonic clock, from when it was first
  received until the server's own lifetime for it (`expires_at` less
  `requested_at`, both the server's times) and an hour more have passed; a
  refused one for the hour alone. The collector's wall clock plays no part,
  so a clock set hours wrong neither forgets an ID early nor keeps it long.
  At most 1,000 are kept, those expiring last.
  """

  @enforce_keys [:ids]
  defstruct @enforce_keys

  @typedoc "When each ID is forgotten, in monotonic milliseconds."
  @type t :: %__MODULE__{ids: %{String.t() => integer()}}

  @grace_ms 3_600_000
  @limit 1_000

  @spec new() :: t()
  def new, do: %__MODULE__{ids: %{}}

  # contract: test/alavi/intake_test.exs "Seen"
  @spec seen?(t(), String.t()) :: boolean()
  def seen?(%__MODULE__{ids: ids}, id), do: Map.has_key?(ids, id)

  @doc "Remember `id`, received at `now` (monotonic milliseconds), for `ttl_ms` and the grace."
  @spec remember(t(), String.t(), non_neg_integer(), integer()) :: t()
  def remember(%__MODULE__{ids: ids}, id, ttl_ms, now) do
    kept =
      ids
      |> Map.put(id, now + ttl_ms + @grace_ms)
      |> Enum.sort_by(fn {_id, forget_at} -> forget_at end, :desc)
      |> Enum.take(@limit)

    %__MODULE__{ids: Map.new(kept)}
  end

  @doc "Forget the IDs whose time has passed at `now` (monotonic milliseconds)."
  @spec prune(t(), integer()) :: t()
  def prune(%__MODULE__{ids: ids}, now),
    do: %__MODULE__{ids: Map.reject(ids, fn {_id, forget_at} -> forget_at < now end)}
end
