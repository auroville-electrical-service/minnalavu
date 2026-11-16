defmodule Alavi.Config.CopyWindow do
  @moduledoc """
  When the collector copies its meters' stored entries each day, by its own
  local wall clock: from `start`, up to but not including `end`. An `end`
  before `start` crosses midnight. Both are whole minutes, and never equal.
  """

  alias Alavi.Config.{Fields, Schema}

  @enforce_keys [:start, :end]
  defstruct @enforce_keys

  @type t :: %__MODULE__{start: Time.t(), end: Time.t()}

  @path ["copy_window"]
  @fields Schema.fields(@path)
  @start Schema.pattern(@path ++ ["start"])
  @stop Schema.pattern(@path ++ ["end"])
  @rule "a time of day as HH:MM on a 24-hour clock"

  # contract: test/alavi/config_test.exs "parse/2"
  @doc false
  @spec parse(term()) :: {:ok, t()} | {:error, String.t()}
  def parse(entry) when is_map(entry) do
    with {:error, reason} <- window(entry), do: {:error, "copy_window: #{reason}"}
  end

  def parse(_entry), do: {:error, "copy_window must be an object with start and end"}

  # contract: test/alavi/config/copy_window_test.exs "open?/2"
  @doc "Whether the local wall-clock time `at` falls in the window."
  @spec open?(t(), Time.t()) :: boolean()
  def open?(%__MODULE__{start: start, end: stop}, at) do
    from_start = Time.compare(at, start) != :lt
    before_end = Time.compare(at, stop) == :lt

    if Time.compare(start, stop) == :lt,
      do: from_start and before_end,
      else: from_start or before_end
  end

  defp window(entry) do
    with :ok <- Fields.only(entry, @fields),
         {:ok, start} <- time(entry, "start", @start),
         {:ok, stop} <- time(entry, "end", @stop),
         :ok <- distinct(start, stop),
         do: {:ok, %__MODULE__{start: start, end: stop}}
  end

  defp time(entry, field, pattern) do
    with {:ok, text} <- Fields.matching(entry, field, pattern, @rule) do
      {:ok, Time.from_iso8601!(text <> ":00")}
    end
  end

  defp distinct(same, same),
    do: {:error, "start and end are both #{format(same)}; the window would be empty"}

  defp distinct(_start, _stop), do: :ok

  defp format(time), do: time |> Time.to_string() |> binary_part(0, 5)
end
