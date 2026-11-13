defmodule Alavi.TestServer do
  @moduledoc """
  An HTTP or HTTPS server for uplink tests, one request per connection.

  Each request is sent to the owner as `{:request, request}` and answered by
  the next of `answers`; the last one keeps answering. An answer is a function
  of the request returning `{status, body}`, or `:close` to drop the connection
  unanswered. A TLS handshake that fails is sent as `{:handshake_failed, reason}`.
  """

  use GenServer

  @type request :: %{
          method: String.t(),
          path: String.t(),
          headers: %{String.t() => String.t()},
          body: binary()
        }
  @type answer :: (request() -> {pos_integer(), iodata()}) | :close

  @doc "Options: `owner` (pid), `answers`, and `tls` (`:ssl` server options) for HTTPS."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @spec port(pid()) :: :inet.port_number()
  def port(server), do: GenServer.call(server, :port)

  @doc "An answer storing the batch: 200 with its batch id, as the server answers."
  @spec stored() :: answer()
  def stored do
    fn %{body: body} ->
      id = JSON.decode!(body)["batch_id"]
      {200, JSON.encode!(%{"batch_id" => id, "readings" => %{}, "missed_reads" => %{}})}
    end
  end

  @doc "An answer with a fixed status and body."
  @spec status(pos_integer(), iodata()) :: answer()
  def status(code, body \\ ""), do: fn _request -> {code, body} end

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    tls = Keyword.get(opts, :tls)
    {:ok, listen, port} = listen(tls)
    server = self()
    spawn_link(fn -> accept_loop(listen, tls, owner, server) end)
    {:ok, %{answers: Keyword.fetch!(opts, :answers), port: port}}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  def handle_call(:next, _from, %{answers: [only]} = state), do: {:reply, only, state}

  def handle_call(:next, _from, %{answers: [next | rest]} = state),
    do: {:reply, next, %{state | answers: rest}}

  @socket [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}]

  defp listen(nil) do
    {:ok, listen} = :gen_tcp.listen(0, @socket)
    {:ok, port} = :inet.port(listen)
    {:ok, listen, port}
  end

  defp listen(tls) do
    {:ok, listen} = :ssl.listen(0, @socket ++ tls)
    {:ok, {_, port}} = :ssl.sockname(listen)
    {:ok, listen, port}
  end

  defp accept_loop(listen, tls, owner, server) do
    case accept(listen, tls) do
      {:ok, socket} -> serve(transport(tls), socket, owner, server)
      {:error, reason} -> send(owner, {:handshake_failed, reason})
    end

    accept_loop(listen, tls, owner, server)
  end

  defp accept(listen, nil), do: :gen_tcp.accept(listen)

  defp accept(listen, _tls) do
    {:ok, socket} = :ssl.transport_accept(listen)
    :ssl.handshake(socket, 5_000)
  end

  defp transport(nil), do: :gen_tcp
  defp transport(_tls), do: :ssl

  defp serve(transport, socket, owner, server) do
    request = read(transport, socket, <<>>)
    send(owner, {:request, request})

    case GenServer.call(server, :next) do
      :close ->
        :ok

      answer ->
        {status, body} = answer.(request)
        body = IO.iodata_to_binary(body)

        :ok =
          transport.send(socket, [
            "HTTP/1.1 #{status} Status\r\n",
            "content-type: application/json\r\n",
            "content-length: #{byte_size(body)}\r\n",
            "connection: close\r\n\r\n",
            body
          ])
    end

    transport.close(socket)
  end

  defp read(transport, socket, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, body] -> request(transport, socket, head, body)
      [_] -> read(transport, socket, acc <> recv!(transport, socket))
    end
  end

  defp request(transport, socket, head, body) do
    [line | header_lines] = String.split(head, "\r\n")
    [method, path, _version] = String.split(line, " ")

    headers =
      Map.new(header_lines, fn header ->
        [name, value] = String.split(header, ":", parts: 2)
        {String.downcase(name), String.trim(value)}
      end)

    length = String.to_integer(Map.get(headers, "content-length", "0"))
    %{method: method, path: path, headers: headers, body: rest(transport, socket, body, length)}
  end

  defp rest(_transport, _socket, body, length) when byte_size(body) >= length, do: body

  defp rest(transport, socket, body, length),
    do: rest(transport, socket, body <> recv!(transport, socket), length)

  defp recv!(transport, socket) do
    {:ok, data} = transport.recv(socket, 0, 5_000)
    data
  end
end
