defmodule Alavi.ReadOnDemandTest do
  use ExUnit.Case, async: true

  import Alavi.PollerCase

  alias Alavi.{Buffer, Clock, FirmwareRead, MissedRead, Poller, Pollers, Reading, TestServer}
  alias Alavi.Uplink
  alias Alavi.Uplink.Target

  @moduletag :capture_log
  @host "127.0.0.1"

  defp chain(port, changes \\ %{}) do
    meters = [meter(1, "elite_440"), meter(2, "elite_440"), meter(3, "elite_500")]
    endpoint(port, "tcp", meters, changes)
  end

  defp poller!(sup) do
    [{_, pid, _, _}] = Supervisor.which_children(sup)
    pid
  end

  # A whole round of the chain: each meter's events, then each meter's names.
  defp round! do
    for _ <- 1..3, do: recorded!()
    for _ <- 1..3, do: assert_receive({:firmware, _}, 2_000)
  end

  defp answer!(ref, timeout \\ 1_000) do
    assert_receive {:alavi_read, ^ref, events}, timeout
    events
  end

  # The next sink or answer message, whichever the poller sent first.
  defp next_message! do
    receive do
      {:recorded, events} -> {:recorded, hd(events).unit_id}
      {:alavi_read, _ref, events} -> {:answer, events |> Enum.map(& &1.unit_id) |> Enum.uniq()}
    after
      2_000 -> flunk("no message from the poller")
    end
  end

  describe "read_now/2" do
    test "a request while the poller waits for the next round is read at once, and answered with its events" do
      {_sim, port} = start_sim!(:tcp)
      sup = start_pollers!([chain(port)])
      round!()

      assert {:ok, ref} = Poller.read_now(poller!(sup), [3, 1])
      events = answer!(ref)

      assert Enum.map(events, & &1.unit_id) == [1, 1, 3, 3, 3, 3]
      assert Enum.all?(events, &match?(%Reading{}, &1))
      assert %Reading{meter_serial: "SIM-3", product_code: "E500C-5102"} = List.last(events)

      # Recorded to the sink like a round's, meter by meter.
      assert [%Reading{unit_id: 1} | _] = recorded!()
      assert [%Reading{unit_id: 3} | _] = recorded!()
    end

    test "a request during a round runs before the rest of it; the round then reads all its meters" do
      {sim, port} = start_sim!(:tcp)
      Simulator.faults(sim, delay_ms: 20)
      sup = start_pollers!([chain(port)])
      assert [%Reading{unit_id: 1} | _] = recorded!()

      assert {:ok, _ref} = Poller.read_now(poller!(sup), [3])
      messages = for _ <- 1..4, do: next_message!()

      # The request lands before or during meter 2's step, never splitting it.
      assert messages in [
               [{:recorded, 3}, {:answer, [3]}, {:recorded, 2}, {:recorded, 3}],
               [{:recorded, 2}, {:recorded, 3}, {:answer, [3]}, {:recorded, 3}]
             ]

      # The round's names steps, after its meters; a read on demand reads no names.
      names =
        for _ <- 1..3 do
          assert_receive {:firmware, %FirmwareRead{unit_id: unit}}, 2_000
          unit
        end

      assert names == [1, 2, 3]
      refute_receive {:firmware, _}, 200
      refute_received {:recorded, _}
    end

    test "leaves when each meter is next due as it was" do
      {_sim, port} = start_sim!(:tcp)

      sup =
        start_pollers!([endpoint(port, "tcp", [meter(1, "elite_440")], %{"interval_ms" => 600})])

      recorded!()
      first = System.monotonic_time(:millisecond)

      Process.sleep(400)
      assert {:ok, ref} = Poller.read_now(poller!(sup), [1])
      answer!(ref)
      recorded!()

      # Due 600 ms after the first round; reset by the request it would be about 1 000 ms.
      recorded!()
      assert System.monotonic_time(:millisecond) - first < 850
    end

    test "requests run one after another, in the order asked" do
      {_sim, port} = start_sim!(:tcp)
      sup = start_pollers!([chain(port)])
      round!()
      pid = poller!(sup)

      assert {:ok, a} = Poller.read_now(pid, [2])
      assert {:ok, b} = Poller.read_now(pid, [1])
      assert [%{unit_id: 2} | _] = answer!(a)
      assert [%{unit_id: 1} | _] = answer!(b)
      refute a == b
    end

    test "an endpoint gone offline answers with a missed read per register" do
      {sim, port} = start_sim!(:tcp)
      sup = start_pollers!([chain(port)])
      round!()
      :ok = Simulator.offline(sim)

      assert {:ok, ref} = Poller.read_now(poller!(sup), [1, 2])
      events = answer!(ref, 2_000)

      # On the connection the round held, or a new one refused: either way, missed.
      assert Enum.map(events, & &1.unit_id) == [1, 1, 2, 2]
      assert Enum.all?(events, &match?(%MissedRead{}, &1))
    end

    test "no unit IDs, or one not on the endpoint, is refused and nothing is read" do
      {_sim, port} = start_sim!(:tcp)
      sup = start_pollers!([chain(port)])
      round!()
      pid = poller!(sup)

      assert Poller.read_now(pid, []) == {:error, :no_units}
      assert Poller.read_now(pid, [1, 9, 9, 4]) == {:error, {:unknown_units, [9, 4]}}
      refute_receive {:recorded, _}, 200
    end

    @tag :tmp_dir
    test "once its events are recorded, an idle uplink sends them at once", %{tmp_dir: dir} do
      buffer = :"buffer_#{System.unique_integer([:positive])}"
      uplink = :"uplink_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Buffer,
         dir: dir,
         max_bytes: 1_000_000,
         max_batch_events: 1_000,
         clock_status: &Clock.unsynced/0,
         name: buffer}
      )

      server = start_supervised!({TestServer, owner: self(), answers: [TestServer.stored()]})

      {:ok, target} =
        Target.parse("http://127.0.0.1:#{TestServer.port(server)}", "t.t.t",
          allow_http: true,
          cacerts: []
        )

      start_supervised!(
        {Uplink,
         buffer: buffer,
         target: target,
         clock: &DateTime.utc_now/0,
         idle_ms: 60_000,
         backoff_ms: %{min: 10, max: 40},
         timeout_ms: 2_000,
         status: no_status(),
         name: uplink}
      )

      {_sim, port} = start_sim!(:tcp)

      sup =
        start_supervised!(
          {Pollers,
           config: config!([endpoint(port, "tcp", [meter(1, "elite_440")])]),
           sink: {Buffer, buffer},
           clock: &DateTime.utc_now/0,
           raw_log: raw_log(),
           status: no_status(),
           uplink: uplink}
        )

      :ok = eventually!(fn -> Buffer.backlog(buffer).events >= 2 end)
      assert {:ok, ref} = Poller.read_now(poller!(sup), [1])
      events = answer!(ref)

      assert_receive {:request, request}, 1_000
      readings = JSON.decode!(request.body)["readings"]
      assert length(readings) == 4
      assert Enum.take(readings, -2) == Enum.map(events, &Reading.to_wire/1)
    end
  end

  describe "Pollers.read_now/3" do
    test "reaches the poller of the endpoint named by host and port" do
      {_sim, port} = start_sim!(:tcp)
      sup = start_pollers!([chain(port)])
      round!()

      assert {:ok, ref} = Pollers.read_now(sup, {@host, port}, [2])
      assert [%Reading{unit_id: 2, endpoint: %{port: ^port}} | _] = answer!(ref)
    end

    test "an endpoint not configured, or polled by another system, is refused" do
      {_sim, port} = start_sim!(:tcp)
      other = refusing_port!()

      sup =
        start_pollers!([
          chain(port),
          endpoint(other, "tcp", [meter(1, "elite_440", %{"serial" => "OTHER-1"})], %{
            "polled_by_other_system" => true
          })
        ])

      assert Pollers.read_now(sup, {@host, other}, [1]) == {:error, :polled_by_other_system}
      assert Pollers.read_now(sup, {"10.9.9.9", port}, [1]) == {:error, :unknown_endpoint}
      assert Pollers.read_now(sup, {@host, port}, [7]) == {:error, {:unknown_units, [7]}}
    end
  end
end
