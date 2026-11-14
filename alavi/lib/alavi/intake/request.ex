defmodule Alavi.Intake.Request do
  @moduledoc """
  One job of the ingest answer's `jobs`, as this collector will run it. The
  only kind it runs is a read on demand; a request names meters by serial,
  never by address.
  """

  @enforce_keys [:id, :meters, :expires_at, :ttl_ms]
  defstruct @enforce_keys

  @typedoc """
  `id` is lower case; `meters` are serials, each once, in the order asked.
  `ttl_ms` is the server's own `expires_at − requested_at`.
  """
  @type t :: %__MODULE__{
          id: String.t(),
          meters: [String.t(), ...],
          expires_at: DateTime.t(),
          ttl_ms: pos_integer()
        }

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  # contract: test/alavi/intake_test.exs "Request.parse/1"
  @doc """
  `{:refuse, id, expires_at, why}` for a well-formed job this collector does
  not run, so that it is remembered like one it ran, among them one without
  a `requested_at` before its `expires_at`; `{:error, why}` for one without a
  usable ID or expiry. Fields besides these five are ignored.
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
      {:ok, serials} ->
        {:ok, %__MODULE__{id: id, meters: serials, expires_at: expires_at, ttl_ms: ttl_ms}}

      {:error, why} ->
        {:refuse, id, expires_at, why}
    end
  end

  defp runnable(%{"kind" => kind}, id, expires_at, _ttl_ms),
    do: {:refuse, id, expires_at, "kind #{excerpt(kind)} is not run here: only read_on_demand"}

  defp runnable(_job, id, expires_at, _ttl_ms), do: {:refuse, id, expires_at, "no kind"}

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
