defmodule Alavi.Intake.Seen do
  @moduledoc """
  The request IDs this collector has run or refused, so that it runs each
  once although every ingest answer lists a request until its first reading
  or missed read arrives. Pure; held in memory only, so a restart forgets it,
  and a request still pending then is run again.

  An ID is kept until an hour after its `expires_at` by the collector's
  clock, which may run ahead of the server's, and at most 1,000 are kept,
  those expiring last.
  """

  @enforce_keys [:ids]
  defstruct @enforce_keys

  @type t :: %__MODULE__{ids: %{String.t() => DateTime.t()}}

  @grace_s 3_600
  @limit 1_000

  @spec new() :: t()
  def new, do: %__MODULE__{ids: %{}}

  # contract: test/alavi/intake_test.exs "Seen"
  @spec seen?(t(), String.t()) :: boolean()
  def seen?(%__MODULE__{ids: ids}, id), do: Map.has_key?(ids, id)

  @spec remember(t(), String.t(), DateTime.t()) :: t()
  def remember(%__MODULE__{ids: ids}, id, expires_at) do
    kept =
      ids
      |> Map.put(id, expires_at)
      |> Enum.sort_by(fn {_id, at} -> at end, {:desc, DateTime})
      |> Enum.take(@limit)

    %__MODULE__{ids: Map.new(kept)}
  end

  @doc "Forget the IDs whose grace after expiry has passed at `now`."
  @spec prune(t(), DateTime.t()) :: t()
  def prune(%__MODULE__{ids: ids}, now) do
    cutoff = DateTime.add(now, -@grace_s, :second)
    %__MODULE__{ids: Map.reject(ids, fn {_id, at} -> DateTime.before?(at, cutoff) end)}
  end
end
