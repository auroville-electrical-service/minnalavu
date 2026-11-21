defmodule Alavi.Copy.Fill do
  @moduledoc """
  A fill request as a poller keeps it until it expires: copy these meters'
  stores between two meter-clock times, outside the nightly mark
  (`Alavi.Copy.Progress`, which a fill never moves). Each meter and store is
  copied once, in a copy window; one whose copy failed is tried again the
  next night, until the request expires.
  """

  alias Alavi.Copy.Stores

  @enforce_keys [:id, :meters, :stores, :from, :to, :expires_at, :done]
  defstruct @enforce_keys

  @typedoc """
  `from` and `to` are the meters' own clock: entries stamped from `from`,
  before `to`. `done` holds each meter and store whose copy has finished.
  """
  @type t :: %__MODULE__{
          id: String.t(),
          meters: [String.t(), ...],
          stores: [Stores.store(), ...],
          from: NaiveDateTime.t(),
          to: NaiveDateTime.t(),
          expires_at: DateTime.t(),
          done: MapSet.t({String.t(), Stores.store()})
        }

  @spec new(
          String.t(),
          [String.t(), ...],
          [Stores.store(), ...],
          NaiveDateTime.t(),
          NaiveDateTime.t(),
          DateTime.t()
        ) :: t()
  def new(id, meters, stores, from, to, expires_at),
    do: %__MODULE__{
      id: id,
      meters: meters,
      stores: stores,
      from: from,
      to: to,
      expires_at: expires_at,
      done: MapSet.new()
    }

  # contract: test/alavi/copy/fill_test.exs "due/2"
  @doc "The stores still to copy of the meter that reported `serial`, in the order asked."
  @spec due(t(), String.t()) :: [Stores.store()]
  def due(%__MODULE__{} = fill, serial) do
    if serial in fill.meters,
      do: Enum.reject(fill.stores, &MapSet.member?(fill.done, {serial, &1})),
      else: []
  end

  # contract: test/alavi/copy/fill_test.exs "due/2"
  @spec done(t(), String.t(), Stores.store()) :: t()
  def done(%__MODULE__{} = fill, serial, store),
    do: %{fill | done: MapSet.put(fill.done, {serial, store})}

  # contract: test/alavi/copy/fill_test.exs "due/2"
  @spec expired?(t(), DateTime.t()) :: boolean()
  def expired?(%__MODULE__{expires_at: at}, now), do: DateTime.compare(now, at) != :lt
end
