defmodule Alavi.Uplink.TargetTest do
  use ExUnit.Case, async: true

  alias Alavi.Uplink.Target

  defp parse(url, opts \\ []),
    do: Target.parse(url, "t.o.k", Keyword.merge([allow_http: false, cacerts: []], opts))

  test "inspect, as a crash report uses it, shows the URL but never the token" do
    {:ok, target} =
      Target.parse("https://store.example", "secret.token", allow_http: false, cacerts: [])

    shown = inspect(target)
    assert shown =~ "https://store.example/rpc/ingest"
    refute shown =~ "secret.token"
  end

  describe "parse/3" do
    test "the ingest and config paths are appended to the base URL's path" do
      assert {:ok,
              %Target{
                url: ~c"https://store.example/api/rpc/ingest",
                config_url: ~c"https://store.example/api/rpc/collector_config"
              }} = parse("https://store.example/api/")
    end

    test "plain http is refused unless explicitly allowed" do
      assert {:error, "server URL http://store.example: must be https://"} =
               parse("http://store.example")

      assert {:ok, %Target{url: ~c"http://store.example/rpc/ingest", ssl: []}} =
               parse("http://store.example", allow_http: true)
    end

    test "https verifies the peer and checks its name" do
      assert {:ok, %Target{ssl: ssl}} = parse("https://store.example:8443")
      assert ssl[:verify] == :verify_peer
      assert ssl[:server_name_indication] == ~c"store.example"
      assert is_function(ssl[:customize_hostname_check][:match_fun])
    end

    test "rejects URLs that are not a plain server address" do
      for url <- [
            "store.example",
            "ftp://store.example",
            "https://",
            "https://user:pw@store.example",
            "https://store.example/?x=1",
            "https://store.example/#x",
            "https://10.0.0.5/"
          ] do
        assert {:error, "server URL " <> _} = parse(url), url
      end
    end

    test "rejects a token that could break the header it goes in" do
      for token <- ["", "a b", "a\r\nX-Evil: 1", "tök"] do
        assert {:error, "server token: " <> _} =
                 Target.parse("https://store.example", token, allow_http: false, cacerts: [])
      end
    end
  end
end
