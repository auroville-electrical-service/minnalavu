defmodule Alavi.Config.Endpoint do
  @moduledoc """
  One IP endpoint in front of an RS-485 chain, and how to poll it; the fields
  are described in `contract/config/config.v1.schema.json`. `max_timeouts` is
  nil for RTU over TCP.
  """

  alias Alavi.Config.{Fields, Meter, Schema}
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
    :copy,
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
          copy: boolean(),
          meters: [Meter.t(), ...]
        }

  @path ["endpoints"]
  @fields Schema.fields(@path)
  @framings %{"tcp" => :tcp, "rtu_over_tcp" => :rtu_over_tcp}
  @host Schema.pattern(@path ++ ["host"])
  @host_rule "an address or name without spaces or control characters"
  @port Schema.range(@path ++ ["port"])
  @max_timeouts Schema.range(@path ++ ["max_timeouts"])
  @timeout Schema.range(@path ++ ["timeout_ms"])
  @retries Schema.range(@path ++ ["retries"])
  @busy Schema.range(@path ++ ["busy_backoff_ms"])
  @backoff_fields Schema.fields(@path ++ ["reconnect_backoff_ms"])
  @backoff_min Schema.range(@path ++ ["reconnect_backoff_ms", "min"])
  @backoff_max Schema.range(@path ++ ["reconnect_backoff_ms", "max"])
  @interval Schema.range(@path ++ ["interval_ms"])

  # contract: test/alavi/config_test.exs "parse/2"
  @doc false
  @spec parse(term(), %{String.t() => Profile.t()}) :: {:ok, t()} | {:error, String.t()}
  def parse(entry, profiles) when is_map(entry) do
    with :ok <- Fields.only(entry, @fields),
         {:ok, host} <- Fields.matching(entry, "host", @host, @host_rule),
         {:ok, port} <- Fields.integer(entry, "port", @port),
         {:ok, framing} <- Fields.lookup(entry, "framing", @framings),
         {:ok, max_timeouts} <- max_timeouts(entry, framing),
         {:ok, other} <- Fields.boolean(entry, "polled_by_other_system"),
         {:ok, timeout} <- Fields.integer(entry, "timeout_ms", @timeout),
         {:ok, retries} <- Fields.integer(entry, "retries", @retries),
         {:ok, busy} <- Fields.integer(entry, "busy_backoff_ms", @busy),
         {:ok, backoff} <- backoff(entry),
         {:ok, interval} <- Fields.integer(entry, "interval_ms", @interval),
         {:ok, copy} <- Fields.boolean(entry, "copy"),
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
         copy: copy,
         meters: meters
       }}
    end
  end

  def parse(_entry, _profiles), do: {:error, "endpoint entry is not an object"}

  defp max_timeouts(entry, :tcp), do: Fields.integer(entry, "max_timeouts", @max_timeouts)

  defp max_timeouts(entry, :rtu_over_tcp) when is_map_key(entry, "max_timeouts"),
    do: {:error, "max_timeouts applies only to framing tcp; RTU over TCP closes on every timeout"}

  defp max_timeouts(_entry, :rtu_over_tcp), do: {:ok, nil}

  defp backoff(entry) do
    with {:ok, %{} = b} <- Map.fetch(entry, "reconnect_backoff_ms"),
         :ok <- Fields.only(b, @backoff_fields),
         {:ok, min} <- Fields.integer(b, "min", @backoff_min),
         {:ok, max} <-
           Fields.integer(b, "max", max(min, @backoff_max.first)..@backoff_max.last//1) do
      {:ok, %{min: min, max: max}}
    else
      {:error, reason} -> {:error, "reconnect_backoff_ms: #{reason}"}
      _ -> {:error, "reconnect_backoff_ms must be an object with min and max"}
    end
  end
end
