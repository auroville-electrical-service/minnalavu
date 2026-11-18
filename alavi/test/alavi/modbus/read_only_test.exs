defmodule Alavi.Modbus.ReadOnlyTest do
  @moduledoc """
  The collector writes nothing to a meter but a selector: the only request
  `Alavi.Modbus.PDU` can build is a read, the one exception is
  `Alavi.Modbus.Selector` (its own tests pin what it can build), only
  `Alavi.Selectors.Session` builds one or has it sent (its tests pin that it
  saves what to put back first), and only the client touches a socket a meter
  could be on (the clock check's UDP socket sends only SNTP).
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Alavi.Modbus.{CRC, Framing, PDU}

  @contract Path.expand("../../../../contract", __DIR__)
  @lib Path.expand("../../../lib", __DIR__)

  # The modules that may call a raw socket module, and which. The uplink
  # reaches the server through :httpc over TLS, which no meter speaks, so :ssl
  # is not here. The clock check sends SNTP over UDP only: Modbus here is TCP
  # or RTU over TCP, never UDP.
  @socket_owners %{
    "alavi/modbus/client.ex" => [:gen_tcp, :gen_udp, :gen_sctp, :socket],
    "alavi/clock/check.ex" => [:gen_udp]
  }
  @socket_modules [:gen_tcp, :gen_udp, :gen_sctp, :socket]

  # The one module allowed to build a write request.
  @selector "alavi/modbus/selector.ex"
  # The one module allowed to ask for one, and to have it sent.
  @session "alavi/selectors/session.ex"
  @client "alavi/modbus/client.ex"
  # Modbus write function codes: coil, register, coils, registers, mask, read/write.
  @write_codes [5, 6, 15, 16, 22, 23]

  describe "read_request/3" do
    test "no request can be built for anything but a read" do
      assert {:error, :invalid_request} = PDU.read_request(:coil, 0, 1)
      assert {:error, :invalid_request} = PDU.read_request(:holding, 0, 126)
      assert {:error, :invalid_request} = PDU.read_request(:holding, 0xFFFF, 2)
    end

    property "from any input, a request is function code 03 or 04, of a read's exact shape" do
      check all table <- member_of([:holding, :input, :coil, :discrete_input, :write]),
                address <- integer(-2..0x10002),
                count <- integer(-2..130),
                unit <- integer(1..247),
                tid <- integer(0..0xFFFF),
                framing <- member_of([:tcp, :rtu_over_tcp]),
                max_runs: 2_000 do
        case PDU.read_request(table, address, count) do
          {:ok, request} -> assert_read(Framing.encode(framing, tid, unit, request), framing)
          {:error, :invalid_request} -> :ok
        end
      end
    end

    test "a request struct is built only in read_request/3, and a write's only in the selector" do
      constructions =
        for file <- lib_files(),
            {name, struct} <- struct_constructions(file),
            kind = request_struct(struct, file),
            kind != nil,
            do: {kind, relative(file), name}

      assert Enum.sort(constructions) == [
               {:read, "alavi/modbus/pdu.ex", :read_request},
               {:write, @selector, :build}
             ]
    end

    test "no binary outside the selector starts with a write function code" do
      files =
        for file <- lib_files(),
            write_binaries(file) != [],
            uniq: true,
            do: relative(file)

      assert files == [@selector]
    end

    test "only the selector session asks for a selector write, or has one sent" do
      callers =
        for file <- lib_files(),
            relative(file) != @client,
            call <- selector_calls(file),
            uniq: true,
            do: {relative(file), call}

      assert Enum.sort(callers) == [{@session, :request}, {@session, :write_selector}]
    end

    # The copy is the collector's only unattended writer: its writes are
    # Session.set/5 alone, each inside a session it opened, and every other
    # request it makes is a read through the poller's client. From Selector it
    # asks only how many entries a register reaches.
    test "the copy writes only through the selector session, and builds no request of its own" do
      copier = Path.join(@lib, "alavi/copy/copier.ex")
      assert copier in lib_files()

      session_calls = remote_calls(copier, :Session)
      assert Enum.sort(Enum.uniq(session_calls)) == [:close, :open, :set]
      # `Client.t()` in its types is no call.
      assert Enum.reject(remote_calls(copier, :Client), &(&1 == :t)) == []
      # `reachable/3` counts the entries a register can select; it builds nothing.
      assert remote_calls(copier, :Selector) == [:reachable]
      assert remote_calls(copier, :PDU) == []
    end

    test "no module but the client calls a socket module, and the clock check only UDP" do
      offenders =
        for file <- lib_files(),
            module <- called_modules(file),
            module in @socket_modules,
            module not in Map.get(@socket_owners, relative(file), []),
            do: {relative(file), module}

      assert offenders == []
    end

    setup do
      fixtures =
        @contract
        |> Path.join("fixtures/modbus-read-requests.v1.json")
        |> File.read!()
        |> JSON.decode!()

      %{fixtures: fixtures}
    end

    test "every read produces exactly its fixture frame", %{fixtures: fixtures} do
      assert fixtures["format"] == "modbus-read-requests/1"

      for read <- fixtures["requests"] do
        {:ok, request} = PDU.read_request(table(read["table"]), read["address"], read["count"])

        frame =
          Framing.encode(
            framing(read["framing"]),
            read["transaction_id"],
            read["unit_id"],
            request
          )

        assert Base.encode16(frame, case: :lower) == read["frame"], inspect(read)
      end
    end

    test "every no_request input is refused", %{fixtures: fixtures} do
      for input <- fixtures["no_request"] do
        assert {:error, :invalid_request} ==
                 PDU.read_request(table(input["table"]), input["address"], input["count"]),
               inspect(input)
      end
    end
  end

  # Each pattern matches the whole frame: 12 bytes for Modbus TCP, 8 for RTU.
  defp assert_read(<<_tid::16, 0::16, 6::16, _unit, fc, _::32>> = frame, :tcp),
    do: assert_read_pdu(fc, frame, 8)

  defp assert_read(<<_unit, fc, _::32, _crc::16>> = frame, :rtu_over_tcp) do
    assert CRC.append(binary_part(frame, 0, 6)) == frame
    assert_read_pdu(fc, frame, 2)
  end

  defp assert_read(frame, framing),
    do: flunk("not a read request (#{framing}): #{inspect(frame)}")

  defp assert_read_pdu(fc, frame, at) do
    assert fc in [3, 4]
    <<address::16, count::16>> = binary_part(frame, at, 4)
    assert count in 1..125
    assert address + count <= 0x10000
  end

  # Maps the fixture's strings to tables by hand, so external text never
  # becomes an atom; an unknown table stays a string and must be refused.
  defp table("holding"), do: :holding
  defp table("input"), do: :input
  defp table(other), do: other

  defp framing("tcp"), do: :tcp
  defp framing("rtu_over_tcp"), do: :rtu_over_tcp

  defp lib_files, do: Path.wildcard(Path.join(@lib, "**/*.ex"))

  defp relative(file), do: Path.relative_to(file, @lib)

  defp quoted(file), do: file |> File.read!() |> Code.string_to_quoted!()

  # Every struct literal or struct/2 call in a def body (not in a function
  # head, where it is a pattern), with the name of the def it is in.
  defp struct_constructions(file) do
    {_, found} =
      Macro.prewalk(quoted(file), [], fn
        {kind, _, [head, [do: body]]} = node, acc when kind in [:def, :defp] ->
          {node, acc ++ Enum.map(structs_in(body), &{def_name(head), &1})}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp structs_in(body) do
    {_, found} =
      Macro.prewalk(body, [], fn
        {:%, _, [name, _]} = node, acc ->
          {node, [name | acc]}

        {struct, _, [name | _]} = node, acc when struct in [:struct, :struct!] ->
          {node, [name | acc]}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp def_name({:when, _, [call | _]}), do: def_name(call)
  defp def_name({name, _, _}), do: name

  defp request_struct({:__MODULE__, _, _}, file), do: own_struct(relative(file))
  defp request_struct({:__aliases__, _, parts}, _file), do: aliased_struct(List.last(parts))
  defp request_struct(_other, _file), do: nil

  defp own_struct("alavi/modbus/pdu.ex"), do: :read
  defp own_struct(@selector), do: :write
  defp own_struct(_file), do: nil

  defp aliased_struct(:PDU), do: :read
  defp aliased_struct(:Selector), do: :write
  defp aliased_struct(_name), do: nil

  # Every bitstring whose first segment is a literal write function code,
  # bare (`<<6, ...>>`) or sized (`<<16::8, ...>>`), constructed or matched.
  defp write_binaries(file) do
    {_, found} =
      Macro.prewalk(quoted(file), [], fn
        {:<<>>, _, [first | _]} = node, acc ->
          if write_code?(first), do: {node, [node | acc]}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp write_code?({:"::", _, [code, _size]}), do: write_code?(code)
  defp write_code?(code), do: code in @write_codes

  # Calls of `Selector.request` (by alias, or `apply/3`), and any mention
  # of `write_selector` at all: a call, a capture, or the bare atom.
  defp selector_calls(file) do
    {_, found} =
      Macro.prewalk(quoted(file), [], fn
        {:., _, [{:__aliases__, _, parts}, :request]} = node, acc ->
          {node, if(List.last(parts) == :Selector, do: [:request | acc], else: acc)}

        {:apply, _, [{:__aliases__, _, parts}, :request | _]} = node, acc ->
          {node, if(List.last(parts) == :Selector, do: [:request | acc], else: acc)}

        {:write_selector, _, _} = node, acc ->
          {node, [:write_selector | acc]}

        {:., _, [_module, :write_selector]} = node, acc ->
          {node, [:write_selector | acc]}

        :write_selector = node, acc ->
          {node, [:write_selector | acc]}

        node, acc ->
          {node, acc}
      end)

    found
  end

  # The functions of the module aliased as `name` that a file calls.
  defp remote_calls(file, name) do
    {_, found} =
      Macro.prewalk(quoted(file), [], fn
        {:., _, [{:__aliases__, _, parts}, fun]} = node, acc when is_atom(fun) ->
          {node, if(List.last(parts) == name, do: [fun | acc], else: acc)}

        node, acc ->
          {node, acc}
      end)

    found
  end

  # Erlang modules called in a file: remote calls and captures
  # (`:gen_tcp.send(...)`, `&:gen_tcp.send/2`) and `apply/3` with a literal module.
  # A bare atom such as an error reason `:socket` is not a call.
  defp called_modules(file) do
    {_, found} =
      Macro.prewalk(quoted(file), [], fn
        {:., _, [module, _fun]} = node, acc when is_atom(module) -> {node, [module | acc]}
        {:apply, _, [module | _]} = node, acc when is_atom(module) -> {node, [module | acc]}
        node, acc -> {node, acc}
      end)

    found
  end
end
