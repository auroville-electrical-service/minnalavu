defmodule Alavi.Status do
  @tick_ms 5_000
  @backlog_timeout_ms 1_000

  @moduledoc """
  Holds the `Alavi.Status.Snapshot` of what the collector is doing, for the
  status page and `status.json`.

  The poller, uplink, config keeper, clock watch and clock check feed it with
  casts only, so they never wait on it, and a cast to it while it is down is dropped. Every `tick_ms` it
  asks the buffer for its backlog (a buffer that does not answer within
  #{@backlog_timeout_ms} ms is shown as not answering), then writes the snapshot to `file`,
  if anything changed since the last write: a temporary file renamed over it,
  so a reader never sees half of one. A failed write is logged once, until one
  succeeds.

  Readers call `read/1`: `Alavi.Status.read(Alavi.Status)` in a release, which
  returns the snapshot; `Alavi.Status.Snapshot.to_json/1` is what the file holds.
  """

  use GenServer

  require Logger

  alias Alavi.{Clock, ClockCheck, Config, FirmwareRead, MissedRead, Reading, Settings}
  alias Alavi.Poller.Latency
  alias Alavi.Status.Snapshot

  @type option ::
          {:config, Config.t()}
          | {:settings, [{String.t(), String.t() | integer()}]}
          | {:version, String.t()}
          | {:buffer, GenServer.server()}
          | {:file, Path.t()}
          | {:clock, (-> DateTime.t())}
          | {:tick_ms, pos_integer()}
          | {:name, GenServer.name()}

  # contract: test/alavi/status_test.exs "start_link/1"
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc "A release's options: `status.json` in `log.dir`, the buffer `Alavi.Buffer`."
  @spec options(Settings.t(), Config.t(), String.t()) :: [option()]
  def options(%Settings{} = settings, %Config{} = config, version) do
    [
      config: config,
      settings: Settings.shown(settings),
      version: version,
      buffer: Alavi.Buffer,
      file: Path.join(settings.log.dir, "status.json"),
      clock: &DateTime.utc_now/0,
      tick_ms: @tick_ms,
      name: __MODULE__
    ]
  end

  # contract: test/alavi/status_test.exs "read/1"
  @spec read(GenServer.server()) :: Snapshot.t()
  def read(server), do: GenServer.call(server, :read)

  # contract: test/alavi/status_test.exs "feeds"
  @doc "One poller round's events, all from one endpoint."
  @spec round(GenServer.server(), [Reading.t() | MissedRead.t()]) :: :ok
  def round(_server, []), do: :ok
  def round(server, events), do: GenServer.cast(server, {:round, events})

  # contract: test/alavi/status_test.exs "feeds"
  @doc "A read on demand's events, all from one endpoint: its meters' values, not a round."
  @spec on_demand(GenServer.server(), [Reading.t() | MissedRead.t()]) :: :ok
  def on_demand(_server, []), do: :ok
  def on_demand(server, events), do: GenServer.cast(server, {:on_demand, events})

  # contract: test/alavi/status_test.exs "feeds"
  @doc "A meter's names, each time the poller reads them."
  @spec firmware(GenServer.server(), FirmwareRead.t()) :: :ok
  def firmware(server, %FirmwareRead{} = read), do: GenServer.cast(server, {:firmware, read})

  # contract: test/alavi/status_test.exs "feeds"
  @doc "Raw-bytes lines as the poller logged them."
  @spec raw_lines(GenServer.server(), [String.t()]) :: :ok
  def raw_lines(_server, []), do: :ok
  def raw_lines(server, lines), do: GenServer.cast(server, {:raw_lines, lines})

  # contract: test/alavi/status_test.exs "feeds"
  @doc "An endpoint's request latency per meter, by unit ID, after each poller job."
  @spec latency(
          GenServer.server(),
          %{host: String.t(), port: :inet.port_number()},
          %{(1..247) => Latency.summary() | nil}
        ) :: :ok
  def latency(server, endpoint, by_unit),
    do: GenServer.cast(server, {:latency, endpoint, by_unit})

  # contract: test/alavi/status_test.exs "feeds"
  @doc "An endpoint's selectors: a restore owed, restored, or a session refused."
  @spec selectors(
          GenServer.server(),
          %{host: String.t(), port: :inet.port_number()},
          Snapshot.selectors_event()
        ) :: :ok
  def selectors(server, endpoint, event),
    do: GenServer.cast(server, {:selectors, endpoint, event})

  # contract: test/alavi/status_test.exs "feeds"
  @spec uplink(GenServer.server(), Snapshot.uplink_result(), non_neg_integer()) :: :ok
  def uplink(server, result, next_ms), do: GenServer.cast(server, {:uplink, result, next_ms})

  # contract: test/alavi/status_test.exs "feeds"
  @doc "The polling config applied, and the served config refused, as `Alavi.ConfigKeeper` holds them."
  @spec config(GenServer.server(), Alavi.ConfigKeeper.report()) :: :ok
  def config(server, report), do: GenServer.cast(server, {:config, report})

  # contract: test/alavi/status_test.exs "feeds"
  @spec clock(GenServer.server(), Clock.status()) :: :ok
  def clock(server, status), do: GenServer.cast(server, {:clock, status})

  # contract: test/alavi/status_test.exs "feeds"
  @doc "The last query of each clock check."
  @spec clock_check(GenServer.server(), ClockCheck.t()) :: :ok
  def clock_check(server, %ClockCheck{} = check),
    do: GenServer.cast(server, {:clock_check, check})

  @impl true
  def init(opts) do
    clock = Keyword.fetch!(opts, :clock)

    snapshot =
      Snapshot.new(
        Keyword.fetch!(opts, :config),
        Keyword.fetch!(opts, :settings),
        Keyword.fetch!(opts, :version),
        clock.()
      )

    state = %{
      snapshot: snapshot,
      buffer: Keyword.fetch!(opts, :buffer),
      file: Keyword.fetch!(opts, :file),
      clock: clock,
      tick_ms: Keyword.fetch!(opts, :tick_ms),
      written: nil,
      failing: false
    }

    {:ok, state, {:continue, :tick}}
  end

  @impl true
  def handle_continue(:tick, state), do: {:noreply, tick(state)}

  @impl true
  def handle_info(:tick, state), do: {:noreply, tick(state)}

  @impl true
  def handle_call(:read, _from, state), do: {:reply, state.snapshot, state}

  @impl true
  def handle_cast({:round, events}, state),
    do: {:noreply, update(state, &Snapshot.round(&1, events))}

  def handle_cast({:on_demand, events}, state),
    do: {:noreply, update(state, &Snapshot.on_demand(&1, events))}

  def handle_cast({:firmware, read}, state),
    do: {:noreply, update(state, &Snapshot.firmware(&1, read))}

  def handle_cast({:raw_lines, lines}, state),
    do: {:noreply, update(state, &Snapshot.raw_lines(&1, lines, state.clock.()))}

  def handle_cast({:latency, endpoint, by_unit}, state),
    do: {:noreply, update(state, &Snapshot.latency(&1, endpoint, by_unit))}

  def handle_cast({:selectors, endpoint, event}, state),
    do: {:noreply, update(state, &Snapshot.selectors(&1, endpoint, event, state.clock.()))}

  def handle_cast({:uplink, result, next_ms}, state),
    do: {:noreply, update(state, &Snapshot.uplink(&1, result, next_ms, state.clock.()))}

  def handle_cast({:config, report}, state),
    do: {:noreply, update(state, &Snapshot.config(&1, report))}

  def handle_cast({:clock, status}, state),
    do: {:noreply, update(state, &Snapshot.clock(&1, status))}

  def handle_cast({:clock_check, check}, state),
    do: {:noreply, update(state, &Snapshot.clock_check(&1, check))}

  defp update(state, change), do: %{state | snapshot: change.(state.snapshot)}

  defp tick(state) do
    Process.send_after(self(), :tick, state.tick_ms)
    state = update(state, &Snapshot.backlog(&1, backlog(state.buffer), state.clock.()))
    write(state, content(state.snapshot))
  end

  # The buffer may be restarting, or busy with a slow disk; neither is the status's to wait on.
  defp backlog(buffer) do
    Alavi.Buffer.backlog(buffer, @backlog_timeout_ms)
  catch
    :exit, _reason -> :unavailable
  end

  # What a write compares: all but the backlog's `as_of`, which changes every tick.
  defp content(%Snapshot{buffer: nil} = snapshot), do: snapshot

  defp content(%Snapshot{buffer: buffer} = snapshot),
    do: %{snapshot | buffer: %{buffer | as_of: nil}}

  defp write(%{written: content} = state, content), do: state

  defp write(state, content) do
    tmp = state.file <> ".tmp"

    with :ok <- File.write(tmp, Snapshot.to_json(state.snapshot)),
         :ok <- File.rename(tmp, state.file) do
      %{state | written: content, failing: false}
    else
      {:error, reason} -> write_failed(state, reason)
    end
  end

  defp write_failed(%{failing: true} = state, _reason), do: state

  defp write_failed(state, reason) do
    Logger.warning(
      "alavi status: cannot write #{state.file}: #{:file.format_error(reason)}; " <>
        "trying again every #{state.tick_ms} ms"
    )

    %{state | failing: true}
  end
end
