defmodule Alavi.Uplink.Target do
  # Shown as the URL only, so a crash report never logs the token or the CA store.
  @derive {Inspect, only: [:url, :config_url]}
  @enforce_keys [:url, :config_url, :token, :ssl]
  defstruct @enforce_keys

  @typedoc "`url` is the ingest URL, `config_url` the served config's; `ssl` is `[]` for plain HTTP."
  @type t :: %__MODULE__{
          url: charlist(),
          config_url: charlist(),
          token: String.t(),
          ssl: [:ssl.tls_client_option()]
        }

  @type option :: {:allow_http, boolean()} | {:cacerts, [:public_key.combined_cert()]}

  @ingest "/rpc/ingest"
  @config "/rpc/collector_config"

  # contract: test/alavi/uplink/target_test.exs "parse/3"
  @spec parse(String.t(), String.t(), [option()]) :: {:ok, t()} | {:error, String.t()}
  def parse(base_url, token, opts) do
    allow_http = Keyword.fetch!(opts, :allow_http)
    cacerts = Keyword.fetch!(opts, :cacerts)

    with {:ok, uri} <- uri(base_url),
         {:ok, ssl} <- ssl(uri, allow_http, cacerts),
         :ok <- token(token) do
      {:ok,
       %__MODULE__{url: url(uri, @ingest), config_url: url(uri, @config), token: token, ssl: ssl}}
    else
      {:error, reason} -> {:error, "server URL #{base_url}: #{reason}"}
      {:token, reason} -> {:error, "server token: #{reason}"}
    end
  end

  defp url(uri, rpc) do
    path = String.trim_trailing(uri.path || "", "/") <> rpc
    %{uri | path: path} |> URI.to_string() |> String.to_charlist()
  end

  defp uri(url) do
    case URI.new(url) do
      {:ok, %URI{host: host, userinfo: nil, query: nil, fragment: nil} = uri}
      when is_binary(host) and host != "" ->
        {:ok, uri}

      _ ->
        {:error, "must be an absolute URL with a host and no user, query or fragment"}
    end
  end

  defp ssl(%URI{scheme: "https", host: host}, _allow_http, cacerts) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, _ip} ->
        {:error, "must name the server by the DNS name its certificate holds, not an IP address"}

      {:error, :einval} ->
        {:ok,
         [
           verify: :verify_peer,
           cacerts: cacerts,
           server_name_indication: String.to_charlist(host),
           customize_hostname_check: [
             match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
           ]
         ]}
    end
  end

  defp ssl(%URI{scheme: "http"}, true, _cacerts), do: {:ok, []}
  defp ssl(_uri, _allow_http, _cacerts), do: {:error, "must be https://"}

  # A bearer token, so it cannot break the header it goes in.
  defp token(token) do
    if is_binary(token) and Regex.match?(~r{^[A-Za-z0-9\-._~+/]+=*$}, token),
      do: :ok,
      else: {:token, "must be a non-empty bearer token (letters, digits, -._~+/)"}
  end
end
