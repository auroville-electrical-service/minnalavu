defmodule Alavi.Wire do
  @moduledoc """
  A batch as the batch schema shapes it, ready for `JSON.encode!/1`. It carries
  no collector id: the server knows the collector from its token.
  """

  alias Alavi.{
    Buffer,
    Clock,
    ClockCheck,
    ConfigKeeper,
    FillResult,
    FirmwareRead,
    LatencyDay,
    MeterClockRead,
    MissedRead,
    Reading,
    StoredEntry
  }

  alias Alavi.Buffer.Batch

  # contract: test/alavi/wire_test.exs "batch/4"
  @doc """
  `sent_at` is the collector's clock. `firmware_reads`, `clock_checks`,
  `latency`, `stored_entries`, `meter_clock_reads` and `fill_results` only when the batch
  holds any; the backlog's `config` only from a
  collector that fetches its config, `:none` otherwise.
  """
  @spec batch(Batch.t(), DateTime.t(), Buffer.backlog(), ConfigKeeper.report() | :none) ::
          %{String.t() => term()}
  def batch(%Batch{} = batch, sent_at, backlog, config) do
    events = Enum.group_by(batch.events, & &1.__struct__)

    %{
      "schema_version" => 1,
      "batch_id" => batch.id,
      "sent_at" => DateTime.to_iso8601(sent_at),
      "clock" => Clock.to_wire(batch.clock),
      "backlog" => backlog |> backlog() |> with_config(config),
      "readings" => wire(events, Reading),
      "missed_reads" => wire(events, MissedRead)
    }
    |> optional("firmware_reads", wire(events, FirmwareRead))
    |> optional("clock_checks", wire(events, ClockCheck))
    |> optional("latency", wire(events, LatencyDay))
    |> optional("stored_entries", wire(events, StoredEntry))
    |> optional("meter_clock_reads", wire(events, MeterClockRead))
    |> optional("fill_results", wire(events, FillResult))
  end

  defp wire(events, kind), do: events |> Map.get(kind, []) |> Enum.map(&kind.to_wire/1)

  defp with_config(backlog, :none), do: backlog
  defp with_config(backlog, report), do: Map.put(backlog, "config", config(report))

  defp optional(batch, _key, []), do: batch
  defp optional(batch, key, items), do: Map.put(batch, key, items)

  @doc """
      iex> Alavi.Wire.backlog(%{events: 0, bytes: 0, batches: 0, oldest: nil,
      ...>   max_bytes: 100, refused: 0, discarded_files: 0, quarantined: 0})["oldest"]
      nil
  """
  @spec backlog(Buffer.backlog()) :: %{String.t() => non_neg_integer() | String.t() | nil}
  def backlog(backlog) do
    %{
      "events" => backlog.events,
      "bytes" => backlog.bytes,
      "batches" => backlog.batches,
      "oldest" => backlog.oldest && DateTime.to_iso8601(backlog.oldest),
      "max_bytes" => backlog.max_bytes,
      "refused" => backlog.refused,
      "discarded_files" => backlog.discarded_files,
      "quarantined" => backlog.quarantined
    }
  end

  @reason_chars 1000

  # contract: test/alavi/wire_test.exs "config/1"
  @doc "A refusal's reason is cut to the #{@reason_chars} characters the batch schema allows."
  @spec config(ConfigKeeper.report()) :: %{String.t() => String.t() | nil}
  def config(%{digest: digest, refused: nil}),
    do: %{"digest" => digest, "refused_digest" => nil, "reason" => nil}

  def config(%{digest: digest, refused: %{digest: refused, reason: reason}}),
    do: %{"digest" => digest, "refused_digest" => refused, "reason" => cut(reason)}

  # The schema counts characters as code points, not graphemes.
  defp cut(reason), do: reason |> String.codepoints() |> Enum.take(@reason_chars) |> Enum.join()
end
