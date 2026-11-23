defmodule Alavi.Status.Web do
  @refresh_s 5

  @moduledoc """
  The status page's HTTP server, on OTP's `:httpd`. It binds 127.0.0.1 here,
  in code, whatever the settings say, so the page is never reachable from
  the network: only the port is configured.

  `GET /` is the summary page and `GET /endpoint/<n>` the page of the `n`th
  endpoint in the polling config, from 1 (`Alavi.Status.Page`, each refreshing
  every #{@refresh_s} s); `GET /status.json` is the snapshot as `status.json`
  holds it. `HEAD` of any answers the same headers. A `Host` other than `127.0.0.1:<port>` or
  `localhost:<port>` gets 421, against DNS rebinding; another method 405;
  another path 404; a status that does not answer, 503.

  If the server cannot start (the port taken, say), that is logged and it is
  not started: the collector polls on without its page, and `status.json` is
  still written.

  No httpd module of its own is loaded, so it serves no file and no directory.
  httpd answers each request in a process of its own and logs its errors to
  the logger; a request that raises gets 500 and touches nothing else.
  """

  require Logger
  require Record

  alias Alavi.Status
  alias Alavi.Status.{Page, Snapshot}

  Record.defrecordp(:mod, Record.extract(:mod, from_lib: "inets/include/httpd.hrl"))

  @loopback {127, 0, 0, 1}
  @html ~c"text/html; charset=utf-8"
  @csp ~c"default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"

  @typedoc "`status`: the `Alavi.Status` to read; `root`: an existing directory, which httpd requires and never serves."
  @type option :: {:port, :inet.port_number()} | {:status, GenServer.server()} | {:root, Path.t()}

  @spec child_spec([option()]) :: Supervisor.child_spec()
  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :supervisor}

  # contract: test/alavi/status/web_test.exs "start_link/1"
  @doc "Starts the server linked to the caller, or logs why it cannot and returns `:ignore`."
  @spec start_link([option()]) :: {:ok, pid()} | :ignore
  def start_link(opts) do
    port = Keyword.fetch!(opts, :port)

    case :inets.start(:httpd, config(opts, port), :stand_alone) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, reason} ->
        Logger.error(
          "alavi status: the status page cannot listen on 127.0.0.1:#{port} " <>
            "(#{inspect(reason)}); collecting goes on without it, and status.json is " <>
            "still written. Free the port or set another status.port, then restart."
        )

        :ignore
    end
  end

  defp config(opts, port) do
    root = opts |> Keyword.fetch!(:root) |> String.to_charlist()

    [
      port: port,
      bind_address: @loopback,
      ipfamily: :inet,
      server_name: ~c"localhost",
      server_root: root,
      document_root: root,
      modules: [__MODULE__],
      server_tokens: :none,
      max_body_size: 1_024,
      logger: [error: :alavi_status],
      alavi_status: Keyword.fetch!(opts, :status)
    ]
  end

  @doc false
  # httpd's module callback.
  @spec unquote(:do)(tuple()) :: {:proceed, [{:response, {:response, list(), binary()}}]}
  def unquote(:do)(mod(config_db: db, method: method, request_uri: uri, parsed_header: headers)) do
    request = %{
      method: to_string(method),
      path: to_string(uri),
      hosts: for({~c"host", host} <- headers, do: to_string(host))
    }

    read = fn -> Status.read(:httpd_util.lookup(db, :alavi_status)) end
    {code, head, body} = respond(request, :httpd_util.lookup(db, :port), read)
    {:proceed, [response: {:response, [{:code, code} | head], body}]}
  end

  defp respond(request, port, read) do
    with :ok <- host(request.hosts, port),
         :ok <- method(request.method),
         {:ok, render} <- route(request.path),
         {:ok, snapshot} <- snapshot(read),
         {:ok, type, body} <- render.(snapshot) do
      answer(request.method, 200, type, body)
    else
      {:error, code, message, extra} ->
        answer(request.method, code, ~c"text/plain; charset=utf-8", message, extra)
    end
  end

  defp host(hosts, port) do
    if hosts in [["127.0.0.1:#{port}"], ["localhost:#{port}"]],
      do: :ok,
      else:
        {:error, 421,
         "Open this page as http://127.0.0.1:#{port}/ or http://localhost:#{port}/\n", []}
  end

  defp method(method) when method in ["GET", "HEAD"], do: :ok

  defp method(_method),
    do: {:error, 405, "This page only shows: GET only.\n", [allow: ~c"GET, HEAD"]}

  defp route("/"), do: {:ok, &{:ok, @html, Page.render(&1, @refresh_s)}}
  defp route("/status.json"), do: {:ok, &{:ok, ~c"application/json", Snapshot.to_json(&1)}}

  defp route("/endpoint/" <> n) do
    if n =~ ~r/\A[1-9][0-9]{0,5}\z/,
      do: {:ok, &endpoint(&1, String.to_integer(n))},
      else: not_found()
  end

  defp route(_path), do: not_found()

  defp endpoint(snapshot, n) do
    case Page.endpoint(snapshot, n, @refresh_s) do
      {:ok, body} -> {:ok, @html, body}
      :error -> not_found()
    end
  end

  defp not_found,
    do:
      {:error, 404,
       "Not found: the summary is at /, endpoint n's page at /endpoint/<n>, " <>
         "and the data at /status.json\n", []}

  # The status may be restarting; the request is answered either way.
  defp snapshot(read) do
    {:ok, read.()}
  catch
    :exit, _reason ->
      {:error, 503, "The collector's status is not answering; try again shortly.\n", []}
  end

  defp answer(method, code, type, body, extra \\ []) do
    head = [
      content_type: type,
      content_length: Integer.to_charlist(byte_size(body)),
      cache_control: ~c"no-store",
      "x-content-type-options": ~c"nosniff",
      "content-security-policy": @csp,
      "referrer-policy": ~c"no-referrer"
    ]

    {code, head ++ extra, if(method == "HEAD", do: "", else: body)}
  end
end
