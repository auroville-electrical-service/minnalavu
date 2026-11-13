defmodule Alavi.Config.Endpoint do
  @moduledoc """
  One IP endpoint in front of an RS-485 chain, and how to poll it.

  - `timeout_ms`: per request and per connect.
  - `max_timeouts`: Modbus TCP only; `nil` for RTU over TCP.
  - `retries`: further attempts at a register after a failed one.
  - `busy_backoff_ms`: the wait before retrying after exception 06.
  - `reconnect_backoff_ms`: the wait between connection attempts, from `min`
    doubling to `max`.
  - `polled_by_other_system`: never connected to.
  """

  alias Alavi.Config.{Fields, Meter}
  alias Alavi.Modbus.Framing
  alias Alavi.Profile

  @enforce_keys [
    :host,
    :port,
    :framing,
    :polled_by_other_system,
    :timeout_ms,
    :max_timeouts,
    :retries,
    :busy_backoff_ms,
    :reconnect_backoff_ms,
    :meters
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          host: String.t(),
          port: :inet.port_number(),
          framing: Framing.t(),
          polled_by_other_system: boolean(),
          timeout_ms: pos_integer(),
          max_timeouts: pos_integer() | nil,
          retries: non_neg_integer(),
          busy_backoff_ms: non_neg_integer(),
          reconnect_backoff_ms: %{min: pos_integer(), max: pos_integer()},
          meters: [Meter.t(), ...]
        }

  @fields [
    "host",
    "port",
    "framing",
    "max_timeouts",
    "polled_by_other_system",
    "timeout_ms",
    "retries",
    "busy_backoff_ms",
    "reconnect_backoff_ms",
    "interval_ms",
    "meters"
  ]
  @framings %{"tcp" => :tcp, "rtu_over_tcp" => :rtu_over_tcp}
  @max_ms 86_400_000

  # contract: test/alavi/config_test.exs "parse/2"
  @doc false
  @spec parse(term(), %{String.t() => Profile.t()}) :: {:ok, t()} | {:error, String.t()}
  def parse(entry, profiles) when is_map(entry) do
    with :ok <- Fields.only(entry, @fields),
         {:ok, host} <- Fields.string(entry, "host"),
         {:ok, port} <- Fields.integer(entry, "port", 1..65_535),
         {:ok, framing} <- Fields.lookup(entry, "framing", @framings),
         {:ok, max_timeouts} <- max_timeouts(entry, framing),
         {:ok, other} <- Fields.boolean(entry, "polled_by_other_system"),
         {:ok, timeout} <- Fields.integer(entry, "timeout_ms", 1..@max_ms),
         {:ok, retries} <- Fields.integer(entry, "retries", 0..10),
         {:ok, busy} <- Fields.integer(entry, "busy_backoff_ms", 0..@max_ms),
         {:ok, backoff} <- backoff(entry),
         {:ok, interval} <- Fields.integer(entry, "interval_ms", 1..@max_ms),
         {:ok, meters} <- Fields.each(entry, "meters", &Meter.parse(&1, interval, profiles)),
         :ok <- Fields.unique(meters, & &1.unit_id, "unit_id") do
      {:ok,
       %__MODULE__{
         host: host,
         port: port,
         framing: framing,
         polled_by_other_system: other,
         timeout_ms: timeout,
         max_timeouts: max_timeouts,
         retries: retries,
         busy_backoff_ms: busy,
         reconnect_backoff_ms: backoff,
         meters: meters
       }}
    end
  end

  def parse(_entry, _profiles), do: {:error, "endpoint entry is not an object"}

  defp max_timeouts(entry, :tcp), do: Fields.integer(entry, "max_timeouts", 1..100)

  defp max_timeouts(entry, :rtu_over_tcp) when is_map_key(entry, "max_timeouts"),
    do: {:error, "max_timeouts applies only to framing tcp; RTU over TCP closes on every timeout"}

  defp max_timeouts(_entry, :rtu_over_tcp), do: {:ok, nil}

  defp backoff(entry) do
    with {:ok, %{} = b} <- Map.fetch(entry, "reconnect_backoff_ms"),
         :ok <- Fields.only(b, ["min", "max"]),
         {:ok, min} <- Fields.integer(b, "min", 1..@max_ms),
         {:ok, max} <- Fields.integer(b, "max", min..@max_ms//1) do
      {:ok, %{min: min, max: max}}
    else
      {:error, reason} -> {:error, "reconnect_backoff_ms: #{reason}"}
      _ -> {:error, "reconnect_backoff_ms must be an object with min and max"}
    end
  end
end
