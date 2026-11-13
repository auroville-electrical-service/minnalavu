defmodule Alavi.Buffer do
  use GenServer

  require Logger

  alias Alavi.Buffer.{Batch, Codec, Segment}
  alias Alavi.{Clock, Sink}

  @behaviour Sink

  @type option ::
          {:dir, Path.t()}
          | {:max_bytes, pos_integer()}
          | {:max_batch_events, pos_integer()}
          | {:clock_status, Clock.status_fun()}
          | {:name, GenServer.name()}

  @typedoc """
  `oldest` is the earliest event timestamp waiting. `refused` counts events
  refused since start. Discarded and quarantined files count towards neither
  `bytes` nor `max_bytes`.
  """
  @type backlog :: %{
          events: non_neg_integer(),
          bytes: non_neg_integer(),
          batches: non_neg_integer(),
          oldest: DateTime.t() | nil,
          max_bytes: pos_integer(),
          refused: non_neg_integer(),
          discarded_files: non_neg_integer(),
          quarantined: non_neg_integer()
        }

  # contract: test/alavi/buffer_test.exs "start_link/1"
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  # contract: test/alavi/buffer_test.exs "record/2"
  @doc "`:ok` only once the events are on disk and synced; a slow disk delays the caller."
  @impl Sink
  @spec record(GenServer.server(), [Sink.event(), ...]) :: :ok | {:error, term()}
  def record(buffer, [_ | _] = events), do: GenServer.call(buffer, {:record, events}, :infinity)

  # contract: test/alavi/buffer_test.exs "take/1"
  @spec take(GenServer.server()) :: {:ok, Batch.t()} | :empty
  def take(buffer), do: GenServer.call(buffer, :take, :infinity)

  # contract: test/alavi/buffer_test.exs "ack/2"
  @spec ack(GenServer.server(), String.t()) ::
          :ok | {:error, :unknown_batch | {:delete, File.posix()}}
  def ack(buffer, id), do: GenServer.call(buffer, {:ack, id}, :infinity)

  # contract: test/alavi/buffer_test.exs "quarantine/3"
  @spec quarantine(GenServer.server(), String.t(), String.t()) ::
          :ok | {:error, :unknown_batch | {:quarantine, File.posix()}}
  def quarantine(buffer, id, reason),
    do: GenServer.call(buffer, {:quarantine, id, reason}, :infinity)

  # contract: test/alavi/buffer_test.exs "backlog/1"
  @spec backlog(GenServer.server()) :: backlog()
  def backlog(buffer), do: GenServer.call(buffer, :backlog)

  @impl GenServer
  def init(opts) do
    dir = Keyword.fetch!(opts, :dir)
    File.mkdir_p!(dir)
    recovered = Segment.recover(dir)

    {:ok,
     %{
       dir: dir,
       max_bytes: Keyword.fetch!(opts, :max_bytes),
       max_events: Keyword.fetch!(opts, :max_batch_events),
       clock_status: Keyword.fetch!(opts, :clock_status),
       sealed: recovered.segments,
       open: nil,
       next: recovered.next,
       refused: 0,
       full: false,
       discarded: recovered.discarded,
       quarantined: recovered.quarantined
     }}
  end

  @impl GenServer
  def handle_call({:record, events}, _from, state) do
    clock = state.clock_status.()
    record = Codec.record(events)
    state = seal_if(state, clock, length(events))

    {reply, state} =
      if bytes(segments(state)) + size(state, clock, record) > state.max_bytes,
        do: full(state, events),
        else: append(state, clock, record, events)

    {:reply, reply, state}
  end

  def handle_call(:take, _from, state) do
    case seal(state) do
      %{sealed: [oldest | _]} = state ->
        batch = %Batch{id: oldest.id, clock: oldest.clock, events: Segment.read!(oldest)}
        {:reply, {:ok, batch}, state}

      state ->
        {:reply, :empty, state}
    end
  end

  def handle_call({:ack, id}, _from, state) do
    case remove(state, id, &Segment.delete/1) do
      {:ok, _segment, state} -> {:reply, :ok, state}
      {:error, :unknown_batch} -> {:reply, {:error, :unknown_batch}, state}
      {:error, reason} -> {:reply, {:error, {:delete, reason}}, state}
    end
  end

  def handle_call({:quarantine, id, why}, _from, state) do
    case remove(state, id, &Segment.quarantine(&1, why)) do
      {:ok, segment, state} ->
        Logger.error(
          "alavi buffer: batch #{id} (#{segment.events} events) quarantined in #{Segment.quarantine_dir(state.dir)}: #{why}"
        )

        {:reply, :ok, %{state | quarantined: state.quarantined + 1}}

      {:error, :unknown_batch} ->
        {:reply, {:error, :unknown_batch}, state}

      {:error, reason} ->
        {:reply, {:error, {:quarantine, reason}}, state}
    end
  end

  def handle_call(:backlog, _from, state) do
    segments = segments(state)

    backlog = %{
      events: segments |> Enum.map(& &1.events) |> Enum.sum(),
      bytes: bytes(segments),
      batches: length(segments),
      oldest: segments |> Enum.map(& &1.oldest) |> Enum.min(DateTime, fn -> nil end),
      max_bytes: state.max_bytes,
      refused: state.refused,
      discarded_files: state.discarded,
      quarantined: state.quarantined
    }

    {:reply, backlog, state}
  end

  defp remove(state, id, move) do
    with {[segment], rest} <- Enum.split_with(state.sealed, &(&1.id == id)),
         :ok <- move.(segment) do
      {:ok, segment, %{state | sealed: rest}}
    else
      {[], _} -> {:error, :unknown_batch}
      {:error, _} = error -> error
    end
  end

  defp seal_if(%{open: {segment, _fd}} = state, clock, n) do
    if segment.clock != clock or segment.events + n > state.max_events,
      do: seal(state),
      else: state
  end

  defp seal_if(state, _clock, _n), do: state

  defp seal(%{open: {segment, fd}} = state) do
    :ok = :file.close(fd)
    %{state | open: nil, sealed: state.sealed ++ [segment]}
  end

  defp seal(state), do: state

  defp size(%{open: {_, _}}, _clock, record), do: byte_size(record)
  defp size(%{open: nil}, clock, record), do: Segment.create_size(clock, record)

  # A failed append has cut its segment back and closed it; it is a batch like any other.
  defp append(%{open: {segment, fd}} = state, _clock, record, events) do
    case Segment.append(segment, fd, record, events) do
      {:ok, segment} ->
        {:ok, accepting(%{state | open: {segment, fd}})}

      {:error, reason} ->
        failed(%{state | open: nil, sealed: state.sealed ++ [segment]}, events, reason)
    end
  end

  defp append(%{open: nil, next: seq} = state, clock, record, events) do
    state = %{state | next: seq + 1}

    case Segment.create(state.dir, seq, clock, record, events) do
      {:ok, segment, fd} -> {:ok, accepting(%{state | open: {segment, fd}})}
      {:error, reason} -> failed(state, events, reason)
    end
  end

  defp failed(state, events, reason) do
    Logger.error(
      "alavi buffer #{state.dir}: write failed, #{length(events)} events not kept: #{inspect(reason)}"
    )

    {{:error, {:write, reason}}, refused(state, events)}
  end

  defp full(state, events) do
    unless state.full do
      Logger.error(
        "alavi buffer #{state.dir}: full at #{state.max_bytes} bytes; new events are refused until batches are acknowledged"
      )
    end

    {{:error, :full}, %{refused(state, events) | full: true}}
  end

  defp refused(state, events), do: %{state | refused: state.refused + length(events)}

  defp accepting(%{full: true} = state) do
    Logger.warning(
      "alavi buffer #{state.dir}: accepting events again; #{state.refused} refused since start"
    )

    %{state | full: false}
  end

  defp accepting(state), do: state

  defp segments(%{open: {segment, _fd}, sealed: sealed}), do: sealed ++ [segment]
  defp segments(%{sealed: sealed}), do: sealed

  defp bytes(segments), do: segments |> Enum.map(& &1.bytes) |> Enum.sum()
end
