defmodule Alavi.Uplink.HTTP do
  @moduledoc """
  One POST of a batch, or one GET of the served config, through OTP's `:httpc`
  and `:ssl`: no native code, so it runs on Windows. Redirects are not followed.
  """

  alias Alavi.Uplink.Target

  @type result :: {:ok, non_neg_integer(), binary()} | {:error, term()}

  # contract: test/alavi/uplink/tls_test.exs "post/3"
  @spec post(Target.t(), iodata(), pos_integer()) :: result()
  def post(%Target{} = target, body, timeout) do
    request = {target.url, headers(target), ~c"application/json", IO.iodata_to_binary(body)}
    request(:post, request, target, timeout)
  end

  # contract: test/alavi/uplink/tls_test.exs "get_config/2"
  @doc "The served config, with the same token and TLS as a POST."
  @spec get_config(Target.t(), pos_integer()) :: result()
  def get_config(%Target{} = target, timeout),
    do: request(:get, {target.config_url, headers(target)}, target, timeout)

  defp headers(target),
    do: [
      {~c"authorization", String.to_charlist("Bearer " <> target.token)},
      {~c"accept", ~c"application/json"}
    ]

  defp request(method, request, target, timeout) do
    options = [timeout: timeout, connect_timeout: timeout, autoredirect: false, ssl: target.ssl]

    case :httpc.request(method, request, options, body_format: :binary) do
      {:ok, {{_version, status, _reason}, _headers, answer}} -> {:ok, status, answer}
      {:error, reason} -> {:error, reason}
    end
  end
end
