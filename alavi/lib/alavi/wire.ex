defmodule Alavi.Wire do
  @moduledoc """
  A batch as the batch schema shapes it, ready for `JSON.encode!/1`. It carries
  no collector id: the server knows the collector from its token.
  """

  alias Alavi.{Buffer, Clock, ClockCheck, FirmwareRead, MissedRead, Reading}
  alias Alavi.Buffer.Batch

  # contract: test/alavi/wire_test.exs "batch/3"
  @doc """
  `sent_at` is the collector's clock. `firmware_reads` and `clock_checks` only
  when the batch holds any.
  """
  @spec batch(Batch.t(), DateTime.t(), Buffer.backlog()) :: %{String.t() => term()}
  def batch(%Batch{} = batch, sent_at, backlog) do
    events = Enum.group_by(batch.events, & &1.__struct__)

    %{
      "schema_version" => 1,
      "batch_id" => batch.id,
      "sent_at" => DateTime.to_iso8601(sent_at),
      "clock" => Clock.to_wire(batch.clock),
      "backlog" => backlog(backlog),
      "readings" => wire(events, Reading),
      "missed_reads" => wire(events, MissedRead)
    }
    |> optional("firmware_reads", wire(events, FirmwareRead))
    |> optional("clock_checks", wire(events, ClockCheck))
  end

  defp wire(events, kind), do: events |> Map.get(kind, []) |> Enum.map(&kind.to_wire/1)

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
end
