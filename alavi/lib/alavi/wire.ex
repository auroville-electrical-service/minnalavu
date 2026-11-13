defmodule Alavi.Wire do
  @moduledoc """
  A batch as the batch schema shapes it, ready for `JSON.encode!/1`. It carries
  no collector id: the server knows the collector from its token.
  """

  alias Alavi.{Buffer, Clock, MissedRead, Reading}
  alias Alavi.Buffer.Batch

  @doc "`sent_at` is the collector's clock."
  @spec batch(Batch.t(), DateTime.t(), Buffer.backlog()) :: %{String.t() => term()}
  def batch(%Batch{} = batch, sent_at, backlog) do
    {readings, missed} = Enum.split_with(batch.events, &match?(%Reading{}, &1))

    %{
      "schema_version" => 1,
      "batch_id" => batch.id,
      "sent_at" => DateTime.to_iso8601(sent_at),
      "clock" => Clock.to_wire(batch.clock),
      "backlog" => backlog(backlog),
      "readings" => Enum.map(readings, &Reading.to_wire/1),
      "missed_reads" => Enum.map(missed, &MissedRead.to_wire/1)
    }
  end

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
