defmodule Alavi.Intake do
  @moduledoc """
  Takes the jobs an ingest answer lists, in the uplink's process, and runs
  each request once (`Alavi.Intake.Seen`): checked against what this
  collector runs (`Alavi.Intake.Request`), its serials resolved to the
  endpoints and units it polls (`Alavi.Intake.Resolve`), then read with
  `Alavi.Pollers.read_now/4`, tagged with the request's ID.

  The resolving and queueing wait on the pollers' steps, so they run in a
  process of their own per request, and the uplink goes on sending. A
  request some of whose serials resolve nowhere has the rest read, and the
  others logged; one none of whose serials resolve is logged and left to
  expire on the server. Either way it is not tried again.
  """

  require Logger

  alias Alavi.{Config, Pollers}
  alias Alavi.Config.Endpoint
  alias Alavi.Intake.{Request, Resolve, Seen}

  @enforce_keys [:pollers, :endpoints, :seen]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          pollers: Supervisor.supervisor(),
          endpoints: [Endpoint.t()],
          seen: Seen.t()
        }

  @spec new(Supervisor.supervisor(), Config.t()) :: t()
  def new(pollers, %Config{endpoints: endpoints}),
    do: %__MODULE__{pollers: pollers, endpoints: endpoints, seen: Seen.new()}

  # contract: test/alavi/intake_test.exs "offer/3"
  @doc "The answer's `jobs`, received at `now` (monotonic milliseconds)."
  @spec offer(t(), term(), integer()) :: t()
  def offer(%__MODULE__{} = intake, jobs, now) when is_list(jobs) do
    intake = %{intake | seen: Seen.prune(intake.seen, now)}
    Enum.reduce(jobs, intake, &take(Request.parse(&1), &2, now))
  end

  def offer(intake, jobs, _now) do
    Logger.warning("alavi intake: jobs is not a list, ignored: #{excerpt(jobs)}")
    intake
  end

  defp take({:error, why}, intake, _now) do
    Logger.warning("alavi intake: job not run: #{why}")
    intake
  end

  defp take({:refuse, id, _expires_at, why}, intake, now) do
    if Seen.seen?(intake.seen, id),
      do: intake,
      else: refuse(remember(intake, id, 0, now), id, why)
  end

  defp take({:ok, %Request{id: id} = request}, intake, now) do
    if Seen.seen?(intake.seen, id),
      do: intake,
      else: start(remember(intake, id, request.ttl_ms, now), request)
  end

  defp remember(intake, id, ttl_ms, now),
    do: %{intake | seen: Seen.remember(intake.seen, id, ttl_ms, now)}

  defp refuse(intake, id, why) do
    Logger.warning("alavi intake: request #{id} not run: #{why}")
    intake
  end

  defp start(intake, request) do
    %__MODULE__{pollers: pollers, endpoints: endpoints} = intake
    {:ok, _pid} = Task.start(fn -> run(request, pollers, endpoints) end)
    intake
  end

  defp run(%Request{id: id, meters: serials}, pollers, endpoints) do
    {plan, unresolved} = Resolve.plan(endpoints, Pollers.serials(pollers), serials)
    unresolved(id, unresolved, plan)
    Enum.each(plan, fn {endpoint, units} -> queue(pollers, id, endpoint, units) end)
  end

  defp unresolved(_id, [], _plan), do: :ok

  defp unresolved(id, unresolved, plan) do
    rest = if plan == [], do: "nothing read; it expires on the server", else: "the rest read"

    Logger.warning(
      "alavi intake: request #{id}: serials not read, #{Enum.map_join(unresolved, ", ", &why/1)}; #{rest}"
    )
  end

  defp why({serial, :not_polled}),
    do: "#{inspect(serial)} not read or configured at any unit this collector polls"

  defp why({serial, :ambiguous}), do: "#{inspect(serial)} read at more than one unit"

  defp queue(pollers, id, {host, port} = endpoint, units) do
    case Pollers.read_now(pollers, endpoint, units, id) do
      {:ok, _ref} ->
        Logger.info(
          "alavi intake: request #{id}: reading #{host}:#{port} units #{inspect(units)}"
        )

      {:error, reason} ->
        Logger.warning(
          "alavi intake: request #{id}: #{host}:#{port} units #{inspect(units)} not read: #{inspect(reason)}"
        )
    end
  end

  defp excerpt(term), do: term |> inspect() |> String.slice(0, 200)
end
