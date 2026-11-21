defmodule Alavi.Buffer.Segment do
  @moduledoc false
  # One segment file of the buffer: the disk side of a batch. File operations
  # only; the format is `Alavi.Buffer.Codec`.
  #
  # Files are written through `:file` in raw mode and never renamed over or
  # reopened for append. A file is closed before it is deleted: Windows refuses
  # to delete an open one.

  require Logger

  alias Alavi.Buffer.Codec
  alias Alavi.{Clock, ClockCheck, FillResult, LatencyDay, MeterClockRead, Sink, StoredEntry}

  @enforce_keys [:seq, :id, :clock, :path, :events, :bytes, :oldest]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          seq: non_neg_integer(),
          id: String.t(),
          clock: Clock.status(),
          path: Path.t(),
          events: non_neg_integer(),
          bytes: non_neg_integer(),
          oldest: DateTime.t() | nil
        }

  @suffix ".seg"
  @discarded ".discarded"
  @quarantine "quarantine"
  @reason ".reason"

  @type recovered :: %{
          segments: [t()],
          next: non_neg_integer(),
          discarded: non_neg_integer(),
          quarantined: non_neg_integer()
        }

  # contract: test/alavi/buffer_test.exs "start_link/1"
  @spec recover(Path.t()) :: recovered()
  def recover(dir) do
    names = File.ls!(dir)
    segments = names |> Enum.flat_map(&seq(&1, @suffix)) |> Enum.sort()
    discarded = Enum.flat_map(names, &seq(&1, @suffix <> @discarded))
    quarantined = quarantined(dir)
    # Quarantined seqs stay taken, so a new segment never shares a name with one.
    next = Enum.max(segments ++ discarded ++ quarantined, fn -> -1 end) + 1
    kept = Enum.flat_map(segments, &recover_one(dir, &1))
    discarded_files = dir |> File.ls!() |> Enum.count(&String.ends_with?(&1, @discarded))
    %{segments: kept, next: next, discarded: discarded_files, quarantined: length(quarantined)}
  end

  @spec quarantine_dir(Path.t()) :: Path.t()
  def quarantine_dir(dir), do: Path.join(dir, @quarantine)

  # contract: test/alavi/buffer_test.exs "quarantine/3"
  @spec quarantine(t(), String.t()) :: :ok | {:error, File.posix()}
  def quarantine(%__MODULE__{path: path}, reason) do
    dir = path |> Path.dirname() |> quarantine_dir()
    target = Path.join(dir, Path.basename(path))

    with :ok <- File.mkdir_p(dir),
         {:ok, fd} <- :file.open(target <> @reason, [:write, :exclusive, :binary, :raw]),
         :ok <- write_new(fd, target <> @reason, reason),
         :ok <- :file.close(fd) do
      File.rename(path, target)
    end
  end

  # contract: test/alavi/buffer_test.exs "record/2"
  @spec create(Path.t(), non_neg_integer(), Clock.status(), binary(), [Sink.event(), ...]) ::
          {:ok, t(), :file.io_device()} | {:error, term()}
  def create(dir, seq, clock, record, events) do
    id = Codec.uuid_v4(:crypto.strong_rand_bytes(16))
    path = path(dir, seq)
    data = Codec.header(id, clock) <> record

    with {:ok, fd} <- :file.open(path, [:write, :exclusive, :binary, :raw]),
         :ok <- write_new(fd, path, data) do
      segment = %__MODULE__{
        seq: seq,
        id: Codec.uuid(id),
        clock: clock,
        path: path,
        events: 0,
        bytes: byte_size(data),
        oldest: nil
      }

      {:ok, count(segment, events), fd}
    end
  end

  @spec create_size(Clock.status(), binary()) :: pos_integer()
  def create_size(clock, record), do: byte_size(Codec.header(<<0::128>>, clock) <> record)

  @doc "On failure the file is cut back to what it held, and closed."
  @spec append(t(), :file.io_device(), binary(), [Sink.event(), ...]) ::
          {:ok, t()} | {:error, term()}
  def append(segment, fd, record, events) do
    case write_sync(fd, record) do
      :ok ->
        {:ok, count(%{segment | bytes: segment.bytes + byte_size(record)}, events)}

      {:error, _} = error ->
        _ = :file.close(fd)
        :ok = truncate(segment.path, segment.bytes)
        error
    end
  end

  @spec read!(t()) :: [Sink.event(), ...]
  def read!(%__MODULE__{path: path}) do
    {:ok, %{records: records}} = path |> File.read!() |> Codec.parse()
    Enum.concat(records)
  end

  @spec delete(t()) :: :ok | {:error, File.posix()}
  def delete(%__MODULE__{path: path}), do: File.rm(path)

  defp count(segment, events) do
    oldest = events |> Enum.map(&at/1) |> Enum.min(DateTime, fn -> nil end)
    %{segment | events: segment.events + length(events), oldest: older(segment.oldest, oldest)}
  end

  defp at(%ClockCheck{t1: t1}), do: t1
  defp at(%LatencyDay{} = day), do: LatencyDay.since(day)
  defp at(%StoredEntry{copied_at: at}), do: at
  defp at(%MeterClockRead{collector_at: at}), do: at
  defp at(%FillResult{finished_at: at}), do: at
  defp at(event), do: event.timestamp

  defp older(nil, b), do: b
  defp older(a, b), do: Enum.min([a, b], DateTime)

  defp recover_one(dir, seq) do
    path = path(dir, seq)
    data = File.read!(path)

    case Codec.parse(data) do
      :error ->
        discard_file(path, data)
        []

      {:ok, %{size: size} = parsed} ->
        if size < byte_size(data), do: discard_tail(path, data, size)
        keep(path, seq, parsed, size)
    end
  end

  defp keep(path, _seq, %{records: []}, _size) do
    :ok = File.rm(path)
    []
  end

  defp keep(path, seq, parsed, size) do
    segment = %__MODULE__{
      seq: seq,
      id: Codec.uuid(parsed.id),
      clock: parsed.clock,
      path: path,
      events: 0,
      bytes: size,
      oldest: nil
    }

    [Enum.reduce(parsed.records, segment, &count(&2, &1))]
  end

  # A header that never became durable guards no kept record: set aside, not deleted, unless empty.
  defp discard_file(path, <<>>) do
    Logger.warning("alavi buffer: #{path} is empty; removed")
    :ok = File.rm(path)
  end

  defp discard_file(path, data) do
    Logger.warning(
      "alavi buffer: #{path} has no valid header; its #{byte_size(data)} bytes are set aside as #{path}#{@discarded}"
    )

    :ok = File.rename(path, path <> @discarded)
  end

  # The tail is copied aside, durably, before the cut: the damage may not be a torn write.
  defp discard_tail(path, data, size) do
    tail = binary_part(data, size, byte_size(data) - size)

    Logger.warning(
      "alavi buffer: #{path} has #{byte_size(tail)} bytes after its last valid record; set aside as #{path}#{@discarded}"
    )

    {:ok, fd} = :file.open(path <> @discarded, [:write, :exclusive, :binary, :raw])
    :ok = write_sync(fd, tail)
    :ok = :file.close(fd)
    :ok = truncate(path, size)
  end

  defp truncate(path, size) do
    {:ok, fd} = :file.open(path, [:read, :write, :binary, :raw])
    {:ok, ^size} = :file.position(fd, size)
    :ok = :file.truncate(fd)
    :ok = :file.sync(fd)
    :file.close(fd)
  end

  # A segment that could not be written whole holds nothing kept: remove it.
  defp write_new(fd, path, data) do
    with {:error, _} = error <- write_sync(fd, data) do
      _ = :file.close(fd)
      _ = File.rm(path)
      error
    end
  end

  defp write_sync(fd, data) do
    with :ok <- :file.write(fd, data), do: :file.sync(fd)
  end

  defp quarantined(dir) do
    case File.ls(quarantine_dir(dir)) do
      {:ok, names} -> Enum.flat_map(names, &seq(&1, @suffix))
      {:error, :enoent} -> []
    end
  end

  defp path(dir, seq),
    do: Path.join(dir, String.pad_leading(Integer.to_string(seq), 20, "0") <> @suffix)

  defp seq(name, suffix) do
    digits = String.replace_suffix(name, suffix, "")

    if digits != name and Regex.match?(~r/^\d{20}$/, digits),
      do: [String.to_integer(digits)],
      else: []
  end
end
