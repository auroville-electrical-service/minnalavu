defmodule Alavi.Status.WebTest do
  use ExUnit.Case, async: true

  import Alavi.PollerCase
  import ExUnit.CaptureLog

  alias Alavi.{FirmwareRead, Reading, Settings, Status}
  alias Alavi.Status.{Snapshot, Web}

  @moduletag :tmp_dir
  @now ~U[2026-11-14 10:00:00Z]
  @example Path.expand("../../../rel/overlays/settings.example.json", __DIR__)
  @token "tok.SECRET-7f3a.sig"
  @hostile "<script>alert(1)</script>"

  defp settings do
    json = @example |> File.read!() |> JSON.decode!() |> put_in(["server", "token"], @token)
    {:ok, settings} = Settings.parse(json)
    settings
  end

  # A status for one endpoint with meters 1 and 3, and its page on a free port.
  defp start!(dir) do
    name = :"status_#{System.unique_integer([:positive])}"

    opts = [
      config: config!([endpoint(5020, "tcp", [meter(1, "elite_440"), meter(3, "elite_440")])]),
      settings: Settings.shown(settings()),
      version: "0.1.0",
      buffer: :no_such_buffer,
      file: Path.join(dir, "status.json"),
      clock: fn -> @now end,
      tick_ms: 60_000,
      name: name
    ]

    start_supervised!({Status, opts})
    port = free_port()
    start_supervised!({Web, port: port, status: name, root: dir})
    :ok = eventually!(fn -> Status.read(name).buffer != nil end)
    {name, port}
  end

  defp reading(unit, serial) do
    %Reading{
      endpoint: %{host: "127.0.0.1", port: 5020},
      unit_id: unit,
      meter_serial: serial,
      product_code: @hostile,
      profile: "elite_440",
      register_key: "active_energy_import",
      timestamp: @now,
      raw_words: [0, 1],
      value: Decimal.new("1234.500"),
      unit: "kWh"
    }
  end

  # One request on its own connection; returns the status code, headers (lowercased names) and body.
  defp request(port, method, path, host \\ :default) do
    host = if host == :default, do: "127.0.0.1:#{port}", else: host
    host_line = if host, do: "Host: #{host}\r\n", else: ""
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])

    :ok =
      :gen_tcp.send(socket, "#{method} #{path} HTTP/1.1\r\n#{host_line}Connection: close\r\n\r\n")

    [head, body] = socket |> recv_all("") |> String.split("\r\n\r\n", parts: 2)
    ["HTTP/1.1 " <> <<code::binary-size(3)>> <> _ | lines] = String.split(head, "\r\n")
    {String.to_integer(code), headers(lines), body}
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> recv_all(socket, acc <> data)
      {:error, :closed} -> acc
    end
  end

  defp headers(lines) do
    Map.new(lines, fn line ->
      [name, value] = String.split(line, ":", parts: 2)
      {String.downcase(name), String.trim(value)}
    end)
  end

  describe "start_link/1" do
    test "listens on 127.0.0.1 only", %{tmp_dir: dir} do
      {_status, port} = start!(dir)

      listening =
        for socket <- Port.list(),
            Port.info(socket, :name) == {:name, ~c"tcp_inet"},
            {:ok, {ip, ^port}} <- [:inet.sockname(socket)],
            do: ip

      assert listening == [{127, 0, 0, 1}]
    end

    test "a port already taken is logged, and the server is not started", %{tmp_dir: dir} do
      {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, port} = :inet.port(socket)
      Process.flag(:trap_exit, true)

      log =
        capture_log(fn ->
          assert :ignore = Web.start_link(port: port, status: :no_status, root: dir)
        end)

      assert log =~ "cannot listen on 127.0.0.1:#{port}"
    end
  end

  describe "GET /" do
    test "the summary escapes what devices sent, and flags a serial mismatch", %{tmp_dir: dir} do
      {status, port} = start!(dir)
      Status.round(status, [reading(1, @hostile), reading(3, "SIM-3")])
      Status.raw_lines(status, ["unit 1: reply <img src=x onerror=alert(2)>"])
      :ok = eventually!(fn -> Status.read(status).raw_lines != [] end)

      {200, headers, body} = request(port, "GET", "/")

      assert headers["content-type"] == "text/html; charset=utf-8"
      assert body =~ ~s|<meta http-equiv="refresh" content="5">|
      refute body =~ "<script"
      refute body =~ "<img"
      assert body =~ "unit 1 serial &lt;script&gt;alert(1)&lt;/script&gt; "
      assert body =~ "&lt;img src=x onerror=alert(2)&gt;"
      assert [_one] = Regex.scan(~r/MISMATCH/, body)
      assert body =~ ~s|<a href="/endpoint/1">127.0.0.1:5020</a>|
      refute body =~ ~r/<(form|button|input|script)/i
    end

    test "answers with headers that keep it from being cached, sniffed or framed", %{tmp_dir: dir} do
      {_status, port} = start!(dir)
      {200, headers, _body} = request(port, "GET", "/")

      assert headers["cache-control"] == "no-store"
      assert headers["x-content-type-options"] == "nosniff"
      assert headers["content-security-policy"] =~ "default-src 'none'"
      refute Map.has_key?(headers, "server")
    end

    test "HEAD answers the headers without the body", %{tmp_dir: dir} do
      {_status, port} = start!(dir)
      {200, headers, body} = request(port, "HEAD", "/")
      assert body == ""
      assert String.to_integer(headers["content-length"]) > 0
    end
  end

  describe "GET /endpoint/<n>" do
    test "is the endpoint's page, escaped, with its register values and a mismatch flagged",
         %{tmp_dir: dir} do
      {status, port} = start!(dir)
      Status.round(status, [reading(1, @hostile), reading(3, "SIM-3")])
      :ok = eventually!(fn -> hd(Status.read(status).endpoints).rounds != [] end)

      {200, headers, body} = request(port, "GET", "/endpoint/1")

      assert headers["content-type"] == "text/html; charset=utf-8"
      assert body =~ ~s|<meta http-equiv="refresh" content="5">|
      assert body =~ "<h1>alavi endpoint 127.0.0.1:5020</h1>"
      refute body =~ "<script"
      assert body =~ "<th>Product code read</th><td>&lt;script&gt;alert(1)&lt;/script&gt;</td>"
      assert body =~ "1234.500"
      assert [_one] = Regex.scan(~r/MISMATCH/, body)
      refute body =~ ~r/<(form|button|input|script)/i
    end

    test "shows each meter's names as last read, escaped, and those not given", %{tmp_dir: dir} do
      {status, port} = start!(dir)

      Status.firmware(status, %FirmwareRead{
        endpoint: %{host: "127.0.0.1", port: 5020},
        unit_id: 1,
        meter_serial: "SIM-1",
        product_code: "ELITE440-445",
        timestamp: @now,
        software: @hostile,
        firmware_1: "SIM-F1",
        firmware_2: nil,
        modbus_version: "0100"
      })

      :ok = eventually!(fn -> hd(hd(Status.read(status).endpoints).meters).firmware != nil end)
      {200, _headers, body} = request(port, "GET", "/endpoint/1")

      refute body =~ "<script"
      assert body =~ "&lt;script&gt;alert(1)&lt;/script&gt; / SIM-F1 / "
      assert body =~ ~s|<span class="note">not given</span> / 0100 at 2026-11-14T10:00:00Z|
    end
  end

  describe "GET /status.json" do
    test "is the snapshot as status.json holds it", %{tmp_dir: dir} do
      {status, port} = start!(dir)
      {200, headers, body} = request(port, "GET", "/status.json")
      assert headers["content-type"] == "application/json"
      assert body == Snapshot.to_json(Status.read(status))
    end
  end

  describe "requests" do
    test "the token appears in neither response", %{tmp_dir: dir} do
      {_status, port} = start!(dir)

      for path <- ["/", "/status.json"] do
        {200, _headers, body} = request(port, "GET", path)
        assert body =~ "server.url"
        refute body =~ "SECRET"
      end
    end

    test "a Host other than 127.0.0.1 or localhost on this port gets 421", %{tmp_dir: dir} do
      {_status, port} = start!(dir)
      assert {200, _, _} = request(port, "GET", "/", "localhost:#{port}")

      for host <- ["evil.example:#{port}", "127.0.0.1", "localhost:1", "10.0.0.5:#{port}"] do
        assert {421, _, body} = request(port, "GET", "/status.json", host)
        refute body =~ "endpoints"
      end

      # Without a Host, httpd refuses HTTP/1.1 itself; HTTP/1.0 is refused here, and httpd
      # sends 421 to an HTTP/1.0 client as 403, which that version has.
      capture_log(fn -> assert {400, _, _} = request(port, "GET", "/status.json", nil) end)
      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, "GET /status.json HTTP/1.0\r\n\r\n")
      assert "HTTP/1.0 403 " <> rest = recv_all(socket, "")
      refute rest =~ "endpoints"
    end

    test "a method other than GET or HEAD gets 405", %{tmp_dir: dir} do
      {_status, port} = start!(dir)

      for method <- ["POST", "PUT", "DELETE", "PATCH", "OPTIONS"] do
        assert {405, %{"allow" => "GET, HEAD"}, _} = request(port, method, "/")
      end
    end

    test "any other path gets 404", %{tmp_dir: dir} do
      {_status, port} = start!(dir)

      paths =
        ["/index.html", "/status.json/", "/../settings.json", "/?x=1", "/status"] ++
          ["/endpoint/2", "/endpoint/0", "/endpoint/01", "/endpoint/-1", "/endpoint/1/"] ++
          ["/endpoint/x", "/endpoint/", "/endpoint", "/endpoint/1?x=1", "/endpoint/9999999"]

      for path <- paths do
        assert {404, _, _} = request(port, "GET", path)
      end
    end

    test "a status that is not running gets 503, and the server goes on", %{tmp_dir: dir} do
      port = free_port()
      pid = start_supervised!({Web, port: port, status: :no_such_status, root: dir})
      assert {503, _, _} = request(port, "GET", "/")
      assert Process.alive?(pid)
    end
  end
end
