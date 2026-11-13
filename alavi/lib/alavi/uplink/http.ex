defmodule Alavi.Uplink.HTTP do
  @moduledoc """
  One POST of a batch, through OTP's `:httpc` and `:ssl`: no native code, so it
  runs on Windows. Redirects are not followed.
  """

  alias Alavi.Uplink.Target

  @type result :: {:ok, non_neg_integer(), binary()} | {:error, term()}

  # contract: test/alavi/uplink/tls_test.exs "post/3"
  @spec post(Target.t(), iodata(), pos_integer()) :: result()
  def post(%Target{} = target, body, timeout) do
    headers = [
      {~c"authorization", String.to_charlist("Bearer " <> target.token)},
      {~c"accept", ~c"application/json"}
    ]

    request = {target.url, headers, ~c"application/json", IO.iodata_to_binary(body)}
    options = [timeout: timeout, connect_timeout: timeout, autoredirect: false, ssl: target.ssl]

    case :httpc.request(:post, request, options, body_format: :binary) do
      {:ok, {{_version, status, _reason}, _headers, answer}} -> {:ok, status, answer}
      {:error, reason} -> {:error, reason}
    end
  end
end
