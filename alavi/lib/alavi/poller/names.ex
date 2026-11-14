defmodule Alavi.Poller.Names do
  @moduledoc false
  # When one meter's firmware names are due to be read, and whether a names
  # read is new enough to send. Pure: the poller holds one per meter.
  #
  # contract: test/alavi/poller/firmware_test.exs "start_link/1"

  alias Alavi.FirmwareRead

  @enforce_keys [:due, :read_at, :identity, :sent]
  defstruct @enforce_keys

  @type identity :: {serial :: String.t(), product_code :: String.t()}
  @typedoc "What a sent read is compared on: everything but its timestamp."
  @type key :: {identity(), [FirmwareRead.name()]}

  @type t :: %__MODULE__{
          due: boolean(),
          read_at: DateTime.t() | nil,
          identity: identity() | nil,
          sent: key() | nil
        }

  @day_s 86_400

  @doc "Due at once: the first round after start reads the names."
  @spec new() :: t()
  def new, do: %__MODULE__{due: true, read_at: nil, identity: nil, sent: nil}

  @doc """
  The identity this round read. Due when it differs from the last round's, or
  the last names read is a day old, or the clock has gone back past it.
  """
  @spec observe(t(), identity(), DateTime.t()) :: t()
  def observe(%__MODULE__{} = names, identity, now) do
    due = names.due or moved?(names.identity, identity) or stale?(names.read_at, now)
    %{names | due: due, identity: identity}
  end

  @spec read(t(), DateTime.t()) :: t()
  def read(%__MODULE__{} = names, now), do: %{names | due: false, read_at: now}

  @spec changed?(t(), FirmwareRead.t()) :: boolean()
  def changed?(%__MODULE__{sent: sent}, %FirmwareRead{} = read), do: key(read) != sent

  @spec sent(t(), FirmwareRead.t()) :: t()
  def sent(%__MODULE__{} = names, %FirmwareRead{} = read), do: %{names | sent: key(read)}

  @doc "The sink refused the read: read the names again next round, and send them."
  @spec refused(t()) :: t()
  def refused(%__MODULE__{} = names), do: %{names | due: true}

  # Before the first round, and before the first read, `due` is already set.
  defp moved?(nil, _identity), do: false
  defp moved?(last, identity), do: last != identity

  defp stale?(nil, _now), do: false

  defp stale?(read_at, now) do
    age = DateTime.diff(now, read_at, :second)
    age >= @day_s or age < 0
  end

  defp key(%FirmwareRead{} = f),
    do:
      {{f.meter_serial, f.product_code},
       [f.software, f.firmware_1, f.firmware_2, f.modbus_version]}
end
