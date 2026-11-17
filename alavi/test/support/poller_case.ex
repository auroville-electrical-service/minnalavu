defmodule Alavi.PollerCase do
  @moduledoc "Helpers for tests that poll a simulated endpoint: configs, simulators, sink messages."

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [start_supervised!: 1, start_supervised!: 2]

  alias Alavi.{Config, Profile}
  alias Simulator.Meter

  @spec profiles() :: %{String.t() => Profile.t()}
  def profiles do
    {:ok, profiles} = Profile.load_dir(Simulator.Profile.dir())
    profiles
  end

  @doc """
  A config endpoint entry with tiny timings, polled at local midnight, so
  that a test on the real clock sees no round but the first unless it sets
  a shorter interval; `changes` replace or add fields.
  """
  @spec endpoint(:inet.port_number(), String.t(), [map()], map()) :: map()
  def endpoint(port, framing, meters, changes \\ %{}) do
    base = %{
      "host" => "127.0.0.1",
      "port" => port,
      "framing" => framing,
      "polled_by_other_system" => false,
      "timeout_ms" => 100,
      "retries" => 2,
      "busy_backoff_ms" => 10,
      "reconnect_backoff_ms" => %{"min" => 10, "max" => 40},
      "interval_ms" => 86_400_000,
      "retry_ms" => 60_000,
      "copy" => false,
      "meters" => meters
    }

    base
    |> Map.merge(if framing == "tcp", do: %{"max_timeouts" => 3}, else: %{})
    |> Map.merge(changes)
  end

  @doc "A config meter entry expecting the serial a simulated meter reports by default."
  @spec meter(1..247, String.t(), map()) :: map()
  def meter(unit_id, profile, changes \\ %{}),
    do:
      Map.merge(
        %{"unit_id" => unit_id, "serial" => "SIM-#{unit_id}", "profile" => profile},
        changes
      )

  @doc "A config document of these endpoint entries, copying from 02:00 to 03:00."
  @spec document([map()]) :: map()
  def document(endpoints),
    do: %{
      "schema_version" => 1,
      "copy_window" => %{"start" => "02:00", "end" => "03:00"},
      "endpoints" => endpoints
    }

  @spec config!([map()]) :: Config.t()
  def config!(endpoints) do
    {:ok, config} = Config.parse(document(endpoints), profiles())
    config
  end

  @doc "A status server that is never started: what is cast to it is dropped."
  @spec no_status() :: atom()
  def no_status, do: Alavi.NoStatus

  @doc "Start an `Alavi.Status` for one unpolled endpoint, writing into `dir`; returns its name."
  @spec start_status!(Path.t()) :: atom()
  def start_status!(dir) do
    name = :"status_#{System.unique_integer([:positive])}"

    opts = [
      config: config!([endpoint(5020, "tcp", [meter(1, "elite_440")])]),
      settings: [],
      version: "0.1.0",
      buffer: :no_such_buffer,
      file: Path.join(dir, "status.json"),
      clock: &DateTime.utc_now/0,
      tick_ms: 60_000,
      name: name
    ]

    start_supervised!({Alavi.Status, opts}, id: name)
    name
  end

  @doc "Poll `check` until it holds, or fail."
  @spec eventually!((-> boolean()), non_neg_integer()) :: :ok
  def eventually!(check, tries \\ 100) do
    cond do
      check.() -> :ok
      tries > 0 -> retry(check, tries)
      true -> flunk("never happened")
    end
  end

  defp retry(check, tries) do
    Process.sleep(10)
    eventually!(check, tries - 1)
  end

  @doc "Raw-bytes log caps for tests: loose enough that nothing is suppressed."
  @spec raw_log() :: Alavi.Poller.RawLog.limits()
  def raw_log, do: %{max_frame_bytes: 256, max_lines: 1000, window_ms: 60_000}

  @doc "Start pollers for `endpoints`, sending each meter's events to the test process."
  @spec start_pollers!([map()], Alavi.Poller.clock(), Alavi.Poller.RawLog.limits()) :: pid()
  def start_pollers!(endpoints, clock \\ &DateTime.utc_now/0, raw_log \\ raw_log()) do
    opts = [
      config: config!(endpoints),
      sink: {Alavi.TestSink, self()},
      clock: clock,
      raw_log: raw_log,
      status: no_status(),
      selectors_dir: selectors_dir!()
    ]

    start_supervised!({Alavi.Pollers, opts})
  end

  @doc "A directory for a poller's selector records, not yet created, removed when the test exits."
  @spec selectors_dir!() :: Path.t()
  def selectors_dir! do
    dir = Path.join(System.tmp_dir!(), "alavi-selectors-#{System.unique_integer([:positive])}")
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  @doc "Start a simulated chain: units 1 and 2 are Elite 440s, 3 an Elite 500."
  @spec start_sim!(:tcp | :rtu_over_tcp, keyword()) :: {pid(), :inet.port_number()}
  def start_sim!(framing, opts \\ []) do
    sim_440 = Simulator.Profile.load!("elite_440")
    sim_500 = Simulator.Profile.load!("elite_500")
    import_ = "active_energy_import"

    meters = [
      Meter.new(1, sim_440, %{import_ => Decimal.new("123456.000")}),
      Meter.new(2, sim_440, %{import_ => Decimal.new("7.500")}),
      Meter.new(3, sim_500, %{import_ => Decimal.new("1234.500")})
    ]

    start_chain!(framing, meters, opts)
  end

  @doc "Start a simulated chain of `meters`."
  @spec start_chain!(:tcp | :rtu_over_tcp, [Meter.t()], keyword()) ::
          {pid(), :inet.port_number()}
  def start_chain!(framing, meters, opts \\ []) do
    spec = {Simulator, [framing: framing, meters: meters] ++ opts}
    sim = start_supervised!(Supervisor.child_spec(spec, id: make_ref(), restart: :temporary))
    {sim, Simulator.port(sim)}
  end

  @doc "The next meter's events from the sink."
  @spec recorded!(timeout()) :: [Alavi.Sink.event()]
  def recorded!(timeout \\ 2_000) do
    assert_receive {:recorded, events}, timeout
    events
  end

  @doc "Sink messages until one for `unit_id` satisfies `pred`; fails after `tries` messages."
  @spec await_unit!(1..247, ([Alavi.Sink.event()] -> boolean()), pos_integer()) ::
          [Alavi.Sink.event()]
  def await_unit!(unit_id, pred, tries \\ 200) do
    events = recorded!()

    cond do
      hd(events).unit_id == unit_id and pred.(events) -> events
      tries > 1 -> await_unit!(unit_id, pred, tries - 1)
      true -> flunk("no matching events for unit #{unit_id}")
    end
  end

  @doc """
  A port that refuses connections for as long as the calling process lives: a
  socket bound to it, never listening, keeps any other test from taking it.
  """
  @spec refusing_port!() :: :inet.port_number()
  def refusing_port! do
    {:ok, socket} = :socket.open(:inet, :stream, :tcp)
    :ok = :socket.bind(socket, %{family: :inet, addr: {127, 0, 0, 1}, port: 0})
    {:ok, %{port: port}} = :socket.sockname(socket)
    port
  end

  @doc """
  What a connect to a refusing port reports in these tests. Windows retries a
  refused connect for about 2 s before reporting it, longer than the tests'
  connect timeouts, so there the connect times out first.
  """
  @spec refused() :: :econnrefused | :timeout
  def refused, do: refused(:os.type())

  defp refused({:win32, _}), do: :timeout
  defp refused(_os), do: :econnrefused

  @doc "The port of a status page started on port 0, read from its httpd's child id."
  @spec web_port(pid()) :: :inet.port_number()
  def web_port(web) do
    [{{:httpd_instance_sup, _address, port, _profile}, _, _, _}] =
      Supervisor.which_children(web)

    port
  end
end
