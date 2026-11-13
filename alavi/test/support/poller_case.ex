defmodule Alavi.PollerCase do
  @moduledoc "Helpers for tests that poll a simulated endpoint: configs, simulators, sink messages."

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [start_supervised!: 1]

  alias Alavi.{Config, Profile}
  alias Simulator.Meter

  @spec profiles() :: %{String.t() => Profile.t()}
  def profiles do
    {:ok, profiles} = Profile.load_dir(Simulator.Profile.dir())
    profiles
  end

  @doc "A config endpoint entry with tiny timings; `changes` replace or add fields."
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
      "interval_ms" => 60_000,
      "meters" => meters
    }

    base
    |> Map.merge(if framing == "tcp", do: %{"max_timeouts" => 3}, else: %{})
    |> Map.merge(changes)
  end

  @spec meter(1..247, String.t(), map()) :: map()
  def meter(unit_id, profile, changes \\ %{}),
    do:
      Map.merge(
        %{"unit_id" => unit_id, "serial" => "SIM-#{profile}-#{unit_id}", "profile" => profile},
        changes
      )

  @spec config!([map()]) :: Config.t()
  def config!(endpoints) do
    {:ok, config} = Config.parse(%{"schema_version" => 1, "endpoints" => endpoints}, profiles())
    config
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
      raw_log: raw_log
    ]

    start_supervised!({Alavi.Pollers, opts})
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

  @doc "A port with nothing listening on it (for now)."
  @spec free_port() :: :inet.port_number()
  def free_port do
    {:ok, listen} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(listen)
    :ok = :gen_tcp.close(listen)
    port
  end
end
