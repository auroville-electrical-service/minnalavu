defmodule Alavi.Intake.Request do
  @moduledoc """
  One job of the ingest answer's `jobs`, as this collector will run it: a
  read on demand, or a fill of the meters' stores between two meter-clock
  times. A request names meters by serial, never by address.
  """

  alias Alavi.Copy.Stores

  @enforce_keys [:id, :kind, :meters, :fill, :expires_at, :ttl_ms]
  defstruct @enforce_keys

  @typedoc """
  `id` is lower case; `meters` are serials, each once, in the order asked.
  `ttl_ms` is the server's own `expires_at − requested_at`. `fill` is a
  fill's stores and its range in the meters' clock, from `from`, before
  `to`; nil for a read on demand.
  """
  @type t :: %__MODULE__{
          id: String.t(),
          kind: :read_on_demand | :fill_copies,
          meters: [String.t(), ...],
          fill: fill() | nil,
          expires_at: DateTime.t(),
          ttl_ms: pos_integer()
        }

  @type fill :: %{stores: [Stores.store(), ...], from: NaiveDateTime.t(), to: NaiveDateTime.t()}

  @stores %{"history" => :history, "snapshot" => :snapshot, "load_survey" => :load_survey}
  @meter_time ~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\z/

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  # contract: test/alavi/intake_test.exs "Request.parse/1"
  @doc """
  `{:refuse, id, expires_at, why}` for a well-formed job this collector does
  not run, so that it is remembered like one it ran, among them one without
  a `requested_at` before its `expires_at`; `{:error, why}` for one without a
  usable ID or expiry. Other fields are ignored.
  """
  @spec parse(term()) ::
          {:ok, t()} | {:refuse, String.t(), DateTime.t(), String.t()} | {:error, String.t()}
  def parse(%{"request_id" => id, "expires_at" => expires} = job) do
    with {:ok, id} <- id(id),
         {:ok, expires_at} <- expiry(expires, id),
         {:ok, ttl_ms} <- ttl(job, id, expires_at) do
      runnable(job, id, expires_at, ttl_ms)
    end
  end

  def parse(job), do: {:error, "a job without a request_id and expires_at: #{excerpt(job)}"}

  defp runnable(%{"kind" => "read_on_demand", "meters" => meters}, id, expires_at, ttl_ms) do
    case serials(meters) do
      {:ok, serials} -> {:ok, request(id, :read_on_demand, serials, nil, expires_at, ttl_ms)}
      {:error, why} -> {:refuse, id, expires_at, why}
    end
  end

  defp runnable(%{"kind" => "fill_copies", "meters" => meters} = job, id, expires_at, ttl_ms) do
    with {:ok, serials} <- serials(meters),
         {:ok, stores} <- stores(Map.get(job, "stores")),
         {:ok, from} <- meter_time(Map.get(job, "from"), "from"),
         {:ok, to} <- meter_time(Map.get(job, "to"), "to"),
         :ok <- ordered(from, to) do
      fill = %{stores: stores, from: from, to: to}
      {:ok, request(id, :fill_copies, serials, fill, expires_at, ttl_ms)}
    else
      {:error, why} -> {:refuse, id, expires_at, why}
    end
  end

  defp runnable(%{"kind" => kind}, id, expires_at, _ttl_ms),
    do:
      {:refuse, id, expires_at,
       "kind #{excerpt(kind)} is not run here: only read_on_demand and fill_copies"}

  defp runnable(_job, id, expires_at, _ttl_ms), do: {:refuse, id, expires_at, "no kind"}

  defp request(id, kind, meters, fill, expires_at, ttl_ms),
    do: %__MODULE__{
      id: id,
      kind: kind,
      meters: meters,
      fill: fill,
      expires_at: expires_at,
      ttl_ms: ttl_ms
    }

  defp stores([_ | _] = names) do
    stores = Enum.map(names, &Map.get(@stores, &1))

    if Enum.all?(stores) and Enum.uniq(names) == names,
      do: {:ok, stores},
      else: {:error, "stores #{excerpt(names)} are not distinct stores"}
  end

  defp stores(names), do: {:error, "stores #{excerpt(names)} name no store"}

  defp meter_time(text, field) when is_binary(text) do
    with true <- text =~ @meter_time,
         {:ok, at} <- NaiveDateTime.from_iso8601(text) do
      {:ok, at}
    else
      _ -> {:error, "#{field} #{excerpt(text)} is not a meter time"}
    end
  end

  defp meter_time(other, field), do: {:error, "#{field} #{excerpt(other)} is not a meter time"}

  defp ordered(from, to) do
    if NaiveDateTime.before?(from, to),
      do: :ok,
      else: {:error, "from #{from} is not before to #{to}"}
  end

  defp ttl(%{"requested_at" => text}, id, expires_at) when is_binary(text) do
    with {:ok, requested_at, _offset} <- DateTime.from_iso8601(text),
         ttl_ms when ttl_ms > 0 <- DateTime.diff(expires_at, requested_at, :millisecond) do
      {:ok, ttl_ms}
    else
      {:error, _} ->
        {:refuse, id, expires_at, "requested_at #{excerpt(text)} is not a timestamp"}

      _not_after ->
        {:refuse, id, expires_at, "expires_at is not after requested_at #{excerpt(text)}"}
    end
  end

  defp ttl(job, id, expires_at),
    do:
      {:refuse, id, expires_at,
       "requested_at #{excerpt(Map.get(job, "requested_at"))} is not a timestamp"}

  defp id(id) when is_binary(id) do
    lower = String.downcase(id)
    if lower =~ @uuid, do: {:ok, lower}, else: {:error, "request_id #{excerpt(id)} is not a UUID"}
  end

  defp id(id), do: {:error, "request_id #{excerpt(id)} is not a UUID"}

  defp expiry(text, id) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> {:ok, at}
      {:error, _} -> {:error, "request #{id}: expires_at #{excerpt(text)} is not a timestamp"}
    end
  end

  defp expiry(other, id),
    do: {:error, "request #{id}: expires_at #{excerpt(other)} is not a timestamp"}

  defp serials([_ | _] = meters) do
    if Enum.all?(meters, &(is_binary(&1) and &1 != "")) and Enum.uniq(meters) == meters,
      do: {:ok, meters},
      else: {:error, "meters #{excerpt(meters)} are not distinct serials"}
  end

  defp serials(meters), do: {:error, "meters #{excerpt(meters)} name no serial"}

  defp excerpt(term), do: term |> inspect() |> String.slice(0, 200)
end
