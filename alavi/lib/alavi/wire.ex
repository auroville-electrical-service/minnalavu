defmodule Alavi.Wire do
  @moduledoc """
  A batch as the batch schema shapes it, ready for `JSON.encode!/1`. It carries
  no collector id: the server knows the collector from its token.
  """

  alias Alavi.{Buffer, Clock, FirmwareRead, MissedRead, Reading}
  alias Alavi.Buffer.Batch

  # contract: test/alavi/wire_test.exs "batch/3"
  @doc "`sent_at` is the collector's clock. `firmware_reads` only when the batch holds any."
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
    |> firmware(wire(events, FirmwareRead))
  end

  defp wire(events, kind), do: events |> Map.get(kind, []) |> Enum.map(&kind.to_wire/1)

  defp firmware(batch, []), do: batch
  defp firmware(batch, reads), do: Map.put(batch, "firmware_reads", reads)

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
