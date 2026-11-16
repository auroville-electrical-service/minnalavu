defmodule Mix.Tasks.Simulator.Run do
  @shortdoc "Serve simulated Elite meters on one TCP endpoint"
  @moduledoc """
  Serve a simulated meter chain until interrupted.

      mix simulator.run --port 5020 --framing tcp --meter 1:elite_440 --meter 3:elite_500

  `--framing` is `tcp` or `rtu_over_tcp`. Active energy import on every meter
  rises by 1 (in the register's unit) each second, so repeated reads show movement.

  Every meter's stores and clock (`Simulator.Stores`, `Simulator.Meter`):

  - `--histories N`, `--snapshots N`, `--days N`: how many billing histories,
    daily snapshots and load-survey days it holds (default 6, the model's
    own snapshot count, 7);
  - `--clock-offset S`: seconds its clock runs ahead of the host's (default
    0; negative behind);
  - `--clock-drift PPM`: millionths it gains on the host's from the start
    (default 0; negative loses).
  """

  use Mix.Task

  alias Simulator.{Meter, Profile}

  @switches [
    port: :integer,
    framing: :string,
    meter: :keep,
    histories: :integer,
    snapshots: :integer,
    days: :integer,
    clock_offset: :integer,
    clock_drift: :integer
  ]

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if rest != [] or invalid != [],
      do: Mix.raise("unknown arguments: #{inspect(rest ++ invalid)}")

    meters = opts |> Keyword.get_values(:meter) |> Enum.map(&(&1 |> meter() |> stored(opts)))
    if meters == [], do: Mix.raise("give at least one --meter UNIT:PROFILE")

    port = Keyword.get(opts, :port) || Mix.raise("--port is required")
    framing = opts |> Keyword.get(:framing) |> framing()

    Mix.Task.run("app.start")
    {:ok, sim} = Simulator.start_link(port: port, framing: framing, meters: meters)
    Mix.shell().info("simulator: #{framing} on 127.0.0.1:#{port}, units #{units(meters)}")
    tick(sim, meters, 1)
  end

  defp meter(spec) do
    with [unit, profile] <- String.split(spec, ":"),
         {unit_id, ""} when unit_id in 1..247 <- Integer.parse(unit),
         true <- File.exists?(Path.join(Profile.dir(), "#{profile}.json")) do
      Meter.new(unit_id, Profile.load!(profile))
    else
      false -> Mix.raise("no profile #{inspect(spec)} in #{Profile.dir()}")
      _ -> Mix.raise("bad --meter #{inspect(spec)}; expected UNIT:PROFILE, e.g. 1:elite_440")
    end
  end

  defp stored(meter, opts) do
    counts = Keyword.take(opts, [:histories, :snapshots, :days])

    if Enum.any?(counts, fn {_, n} -> n not in 0..0xFFFF end),
      do: Mix.raise("--histories, --snapshots and --days must be 0 to 65535")

    meter
    |> Meter.stores(counts)
    |> Meter.clock(Keyword.get(opts, :clock_offset, 0), Keyword.get(opts, :clock_drift, 0))
  end

  defp framing("tcp"), do: :tcp
  defp framing("rtu_over_tcp"), do: :rtu_over_tcp

  defp framing(other),
    do: Mix.raise("--framing must be tcp or rtu_over_tcp, got #{inspect(other)}")

  defp units(meters), do: Enum.map_join(meters, ", ", & &1.unit_id)

  defp tick(sim, meters, n) do
    Process.sleep(1000)
    Enum.each(meters, &Simulator.put(sim, &1.unit_id, "active_energy_import", Decimal.new(n)))
    tick(sim, meters, n + 1)
  end
end
