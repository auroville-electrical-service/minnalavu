defmodule Simulator do
  @moduledoc """
  A simulated meter endpoint: one TCP port in front of an RS-485 chain of Elite
  meters, each answering at its own Modbus unit id.

      profile = Simulator.Profile.load!("elite_440")
      {:ok, sim} = Simulator.start_link(framing: :tcp, meters: [Simulator.Meter.new(1, profile)])
      port = Simulator.port(sim)

  Only read requests (function codes 03/04) are answered; anything else gets
  exception 01, illegal function.
  """

  alias Simulator.{Faults, Meter}

  @type option ::
          {:port, :inet.port_number()}
          | {:framing, :tcp | :rtu_over_tcp}
          | {:meters, [Meter.t()]}
          | {:max_connections, pos_integer()}
          | {:missing_units, Simulator.Protocol.missing_units()}

  @doc """
  Start an endpoint on 127.0.0.1. `port` 0 (the default) picks a free port.
  `max_connections` defaults to 1, like most meter Ethernet modules.
  `missing_units`: `:silent` (default) or `:gateway_error`, exception 0B as a
  gateway sends.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.merge([port: 0, max_connections: 1, missing_units: :silent], opts)
    GenServer.start_link(Simulator.Server, opts)
  end

  @doc "Child spec for `start_supervised/1` in tests."
  @spec child_spec([option()]) :: Supervisor.child_spec()
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @doc "The TCP port the endpoint listens on."
  @spec port(GenServer.server()) :: :inet.port_number()
  def port(sim), do: GenServer.call(sim, :port)

  @doc "Set a register value on the meter at `unit_id`."
  @spec put(GenServer.server(), 1..247, String.t(), Decimal.t()) :: :ok
  def put(sim, unit_id, key, value), do: GenServer.call(sim, {:put, unit_id, key, value})

  @doc "Set what the meter at `unit_id` reports for an identity check. See `Simulator.Meter`."
  @spec identify(GenServer.server(), 1..247, Meter.check(), term()) :: :ok
  def identify(sim, unit_id, check, value),
    do: GenServer.call(sim, {:identify, unit_id, check, value})

  @doc "Change faults; fields not given keep their value. See `Simulator.Faults`."
  @spec faults(GenServer.server(), keyword()) :: :ok
  def faults(sim, changes) do
    changes = Keyword.update(changes, :silent_units, nil, &MapSet.new/1)
    changes = Enum.reject(changes, fn {_k, v} -> is_nil(v) end)
    GenServer.call(sim, {:faults, changes})
  end

  @doc "Clear all faults."
  @spec clear_faults(GenServer.server()) :: :ok
  def clear_faults(sim), do: GenServer.call(sim, {:faults, Map.from_struct(%Faults{})})
end
