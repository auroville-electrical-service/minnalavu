defmodule Alavi.Uplink.TLSTest do
  use ExUnit.Case, async: true

  alias Alavi.TestServer
  alias Alavi.Uplink.{HTTP, Target}

  @moduletag :capture_log

  # A CA and a server certificate for `host`, made for the test.
  defp chain(host) do
    key = [key: {:namedCurve, :secp256r1}, digest: :sha256]
    san = {:Extension, {2, 5, 29, 17}, false, [{:dNSName, String.to_charlist(host)}]}

    :public_key.pkix_test_data(%{
      server_chain: %{root: key, intermediates: [], peer: key ++ [extensions: [san]]},
      client_chain: %{root: key, intermediates: [], peer: key}
    })[:server_config]
  end

  defp post(port, cacerts) do
    {:ok, target} =
      Target.parse("https://localhost:#{port}", "t.o.k", allow_http: false, cacerts: cacerts)

    HTTP.post(target, ~s({"batch_id":"b"}), 2_000)
  end

  defp server!(tls) do
    answer = TestServer.status(200, ~s({"batch_id":"b"}))
    pid = start_supervised!({TestServer, owner: self(), answers: [answer], tls: tls})
    TestServer.port(pid)
  end

  describe "post/3" do
    test "a server whose certificate chains to a trusted CA and names the host is reached" do
      tls = chain("localhost")
      port = server!(tls)
      assert {:ok, 200, ~s({"batch_id":"b"})} = post(port, tls[:cacerts])
      assert_receive {:request, %{path: "/rpc/ingest"}}
    end

    test "a server whose certificate does not chain to a trusted CA is refused" do
      port = server!(chain("localhost"))
      assert {:error, {:failed_connect, _}} = post(port, :public_key.cacerts_get())
      refute_receive {:request, _}, 100
    end

    test "a server whose certificate names another host is refused" do
      tls = chain("store.example")
      port = server!(tls)
      assert {:error, {:failed_connect, _}} = post(port, tls[:cacerts])
      refute_receive {:request, _}, 100
    end
  end

  describe "get_config/2" do
    test "the served config is fetched with the collector's token, verifying the server alike" do
      tls = chain("localhost")
      port = server!(tls)

      {:ok, target} =
        Target.parse("https://localhost:#{port}", "t.o.k",
          allow_http: false,
          cacerts: tls[:cacerts]
        )

      assert {:ok, 200, _body} = HTTP.get_config(target, 2_000)

      assert_receive {:request, %{method: "GET", path: "/rpc/collector_config", headers: headers}}

      assert headers["authorization"] == "Bearer t.o.k"

      {:ok, untrusted} =
        Target.parse("https://localhost:#{port}", "t.o.k",
          allow_http: false,
          cacerts: :public_key.cacerts_get()
        )

      assert {:error, {:failed_connect, _}} = HTTP.get_config(untrusted, 2_000)
    end
  end
end
