defmodule Alavi.Uplink.Response do
  @type decision :: {:ack, map()} | {:quarantine, String.t()} | {:retry, String.t()}

  @excerpt 300

  # contract: test/alavi/uplink/response_test.exs "decide/2"
  @spec decide(Alavi.Uplink.HTTP.result(), String.t()) :: decision()
  def decide({:ok, 200, body}, batch_id) do
    case JSON.decode(body) do
      {:ok, %{"batch_id" => id} = answer} when is_binary(id) ->
        if String.downcase(id) == String.downcase(batch_id),
          do: {:ack, answer},
          else: {:retry, "HTTP 200 answered for batch #{id}, not #{batch_id}"}

      _ ->
        {:retry, "HTTP 200 without an answer for the batch: #{excerpt(body)}"}
    end
  end

  def decide({:ok, 413, body}, _batch_id), do: {:quarantine, "HTTP 413: #{excerpt(body)}"}

  def decide({:ok, status, body}, _batch_id) when status in [400, 409, 422] do
    case JSON.decode(body) do
      {:ok, %{"code" => code} = error} when is_binary(code) ->
        {:quarantine, "HTTP #{status} #{code}: #{message(error["message"])}"}

      _ ->
        {:retry, "HTTP #{status} without a server error body: #{excerpt(body)}"}
    end
  end

  def decide({:ok, status, body}, _batch_id), do: {:retry, "HTTP #{status}: #{excerpt(body)}"}
  def decide({:error, reason}, _batch_id), do: {:retry, "no answer: #{inspect(reason)}"}

  defp message(text) when is_binary(text), do: excerpt(text)
  defp message(other), do: inspect(other)

  defp excerpt(body),
    do:
      body
      |> String.replace_invalid()
      |> String.slice(0, @excerpt)
      |> String.replace(~r/\s+/, " ")
end
