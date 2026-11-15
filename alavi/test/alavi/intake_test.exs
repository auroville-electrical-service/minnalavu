defmodule Alavi.IntakeTest do
  use ExUnit.Case, async: true

  import Alavi.PollerCase
  import ExUnit.CaptureLog

  alias Alavi.{Intake, Pollers, Reading}
  alias Alavi.Intake.{Request, Resolve, Seen}

  @moduletag :capture_log
  @host "127.0.0.1"
  @id "7d2c1f0e-4b3a-4c5d-8e6f-1a2b3c4d5e6f"
  @other "0b6f8d2e-5c1a-4e7b-9a3d-2f4c6e8a0b1c"
  @now 0

  defp job(changes \\ %{}) do
    Map.merge(
      %{
        "request_id" => @id,
        "kind" => "read_on_demand",
        "meters" => ["SIM-3"],
        "requested_at" => "2026-11-01T00:00:00+00:00",
        "expires_at" => "2026-11-01T01:00:00+00:00"
      },
      changes
    )
  end

  defp chain(port),
    do:
      endpoint(port, "tcp", Enum.map([1, 2], &meter(&1, "elite_440")) ++ [meter(3, "elite_500")])

  # A whole round of the chain: each meter's events, then each meter's names.
  defp round! do
    for _ <- 1..3, do: recorded!()
    for _ <- 1..3, do: assert_receive({:firmware, _}, 2_000)
  end

  # The next recorded events carrying a request id.
  defp requested!(tries \\ 20) do
    case recorded!() do
      [%{request_id: id} | _] = events when id != nil -> events
      _round when tries > 0 -> requested!(tries - 1)
    end
  end

  describe "Request.parse/1" do
    test "a read on demand, its id in lower case" do
      assert Request.parse(job(%{"request_id" => String.upcase(@id), "meters" => ["A", "B"]})) ==
               {:ok,
                %Request{
                  id: @id,
                  meters: ["A", "B"],
                  expires_at: ~U[2026-11-01 01:00:00Z],
                  ttl_ms: 3_600_000
                }}
    end

    test "another kind, or meters that are not distinct serials, is refused under its id" do
      expires = ~U[2026-11-01 01:00:00Z]

      for changes <- [
            %{"kind" => "store_copy"},
            %{"meters" => []},
            %{"meters" => ["A", "A"]},
            %{"meters" => ["A", ""]},
            %{"meters" => [1]},
            %{"meters" => "A"}
          ] do
        assert {:refuse, @id, ^expires, _why} = Request.parse(job(changes))
      end

      assert {:refuse, @id, ^expires, "no kind"} = Request.parse(Map.delete(job(), "kind"))
    end

    test "a job without a requested_at before its expires_at is refused under its id" do
      expires = ~U[2026-11-01 01:00:00Z]

      for changes <- [
            %{"requested_at" => "earlier"},
            %{"requested_at" => nil},
            %{"requested_at" => "2026-11-01T01:00:00+00:00"},
            %{"requested_at" => "2026-11-01T02:00:00+00:00"}
          ] do
        assert {:refuse, @id, ^expires, _why} = Request.parse(job(changes))
      end

      assert {:refuse, @id, ^expires, _why} = Request.parse(Map.delete(job(), "requested_at"))
    end

    test "a job without a usable id or expiry is an error" do
      for job <- [
            job(%{"request_id" => "request-1"}),
            job(%{"request_id" => 1}),
            job(%{"expires_at" => "soon"}),
            job(%{"expires_at" => nil}),
            Map.delete(job(), "request_id"),
            "a job"
          ] do
        assert {:error, _why} = Request.parse(job)
      end
    end
  end

  describe "Seen" do
    test "an id is remembered from its receipt for its lifetime and an hour more" do
      seen = Seen.remember(Seen.new(), @id, 3_600_000, @now)
      assert Seen.seen?(seen, @id)
      refute Seen.seen?(seen, @other)
      assert seen |> Seen.prune(@now + 7_200_000) |> Seen.seen?(@id)
      refute seen |> Seen.prune(@now + 7_200_001) |> Seen.seen?(@id)
    end

    test "at most 1,000 are kept, those expiring last" do
      seen =
        Enum.reduce(0..1_000, Seen.new(), fn n, seen ->
          Seen.remember(seen, "id-#{n}", 3_600_000, @now + n)
        end)

      assert map_size(seen.ids) == 1_000
      refute Seen.seen?(seen, "id-0")
      assert Seen.seen?(seen, "id-1") and Seen.seen?(seen, "id-1000")
    end
  end

  describe "Resolve.plan/3" do
    defp endpoints do
      config!([
        endpoint(5020, "tcp", [meter(1, "elite_440"), meter(2, "elite_440")]),
        endpoint(5021, "tcp", [
          meter(1, "elite_440", %{"serial" => "B-1"}),
          Map.delete(meter(4, "elite_440"), "serial")
        ]),
        endpoint(5022, "tcp", [meter(1, "elite_440", %{"serial" => "OTHER-1"})], %{
          "polled_by_other_system" => true
        })
      ]).endpoints
    end

    test "a serial resolves by the config where none was read, grouped per endpoint in the order asked" do
      assert Resolve.plan(endpoints(), %{}, ["SIM-2", "B-1", "SIM-1"]) ==
               {[{{@host, 5020}, [2, 1]}, {{@host, 5021}, [1]}], []}
    end

    test "the serial last read at a unit wins over the config's" do
      observed = %{{@host, 5020} => %{2 => "SWAPPED"}, {@host, 5021} => %{4 => "READ-4"}}

      assert Resolve.plan(endpoints(), observed, ["SWAPPED", "READ-4", "SIM-2"]) ==
               {[{{@host, 5020}, [2]}, {{@host, 5021}, [4]}], [{"SIM-2", :not_polled}]}
    end

    test "a serial polled by another system, unknown, or at two units does not resolve" do
      observed = %{{@host, 5021} => %{4 => "SIM-1"}}

      assert Resolve.plan(endpoints(), observed, ["OTHER-1", "NOPE", "SIM-1", "B-1"]) ==
               {[{{@host, 5021}, [1]}],
                [{"OTHER-1", :not_polled}, {"NOPE", :not_polled}, {"SIM-1", :ambiguous}]}
    end
  end

  describe "Pollers.serials/1" do
    test "the serial last read at each unit, per running poller" do
      {sim, port} = start_sim!(:tcp)
      Simulator.identify(sim, 3, :serial, "READ-3")
      other = refusing_port!()

      sup =
        start_pollers!([
          chain(port),
          endpoint(other, "tcp", [meter(1, "elite_440", %{"serial" => "OTHER-1"})], %{
            "polled_by_other_system" => true
          })
        ])

      round!()

      assert Pollers.serials(sup) == %{
               {@host, port} => %{1 => "SIM-1", 2 => "SIM-2", 3 => "READ-3"}
             }
    end
  end

  describe "offer/3" do
    setup do
      {sim, port} = start_sim!(:tcp)
      endpoints = [chain(port)]
      sup = start_pollers!(endpoints)
      round!()
      {:ok, sim: sim, port: port, sup: sup, intake: Intake.new(sup, config!(endpoints))}
    end

    test "a request is read once, tagged with its id, however often it is listed", ctx do
      intake = Intake.offer(ctx.intake, [job()], @now)
      events = requested!()
      assert [%Reading{unit_id: 3} | _] = events
      assert Enum.all?(events, &(&1.request_id == @id))

      Intake.offer(intake, [job(%{"request_id" => String.upcase(@id)})], @now)
      refute_receive {:recorded, [%{request_id: @id} | _]}, 300
    end

    test "a request is run once however far the collector's clock is from the server's", ctx do
      # Server times hours behind a fast collector clock, and years ahead of a slow one.
      for {id, {requested, expires}} <- [
            {@id, {"2000-01-01T00:00:00Z", "2000-01-01T01:00:00Z"}},
            {@other, {"2100-01-01T00:00:00Z", "2100-01-01T01:00:00Z"}}
          ] do
        listed = [
          job(%{"request_id" => id, "requested_at" => requested, "expires_at" => expires})
        ]

        intake = Intake.offer(ctx.intake, listed, @now)
        assert [%Reading{unit_id: 3, request_id: ^id} | _] = requested!()

        intake = Intake.offer(intake, listed, @now + 60_000)
        Intake.offer(intake, listed, @now + 7_200_000)
        refute_receive {:recorded, [%{request_id: ^id} | _]}, 300
      end
    end

    test "the serial read at a unit is what a request finds it by", ctx do
      Simulator.identify(ctx.sim, 2, :serial, "READ-2")
      # A read of unit 2 that reads the new serial, as a round would.
      {:ok, _ref} = Pollers.read_now(ctx.sup, {@host, ctx.port}, [2])
      assert [%Reading{meter_serial: "READ-2", request_id: nil} | _] = recorded!()

      log =
        capture_log(fn ->
          Intake.offer(ctx.intake, [job(%{"meters" => ["SIM-2", "READ-2"]})], @now)

          assert [%Reading{unit_id: 2, meter_serial: "READ-2", request_id: @id} | _] =
                   requested!()
        end)

      assert log =~ "\"SIM-2\" not read or configured" and log =~ "the rest read"
    end

    test "a request none of whose serials resolve reads nothing, and says it is left to expire",
         ctx do
      log =
        capture_log(fn ->
          Intake.offer(ctx.intake, [job(%{"meters" => ["NOPE"]})], @now)
          refute_receive {:recorded, [%{request_id: @id} | _]}, 300
        end)

      assert log =~ "request #{@id}" and log =~ "expires on the server"
    end

    test "a request refused or malformed is logged, a refused one once", ctx do
      log =
        capture_log(fn ->
          refused = job(%{"kind" => "store_copy"})
          intake = Intake.offer(ctx.intake, [refused, job(%{"request_id" => "x"})], @now)
          Intake.offer(intake, [refused], @now)
          Intake.offer(intake, %{"not" => "a list"}, @now)
          refute_receive {:recorded, [%{request_id: @id} | _]}, 300
        end)

      assert [_] = Regex.scan(~r/store_copy/, log)
      assert log =~ ~s|request_id "x" is not a UUID| and log =~ "jobs is not a list"
    end

    test "an id is forgotten its lifetime and an hour after receipt, so listed again it is run again",
         ctx do
      intake = Intake.offer(ctx.intake, [job(%{"meters" => ["SIM-1"]})], @now)
      assert [%Reading{unit_id: 1, request_id: @id} | _] = requested!()
      Intake.offer(intake, [job(%{"meters" => ["SIM-1"]})], @now + 7_200_001)
      assert [%Reading{unit_id: 1, request_id: @id} | _] = requested!()
    end
  end

  describe "configured/2" do
    test "serials resolve against the config applied; requests already run stay run" do
      {_sim, port} = start_sim!(:tcp)
      sup = start_pollers!([chain(port)])
      round!()
      elsewhere = Intake.new(sup, config!([endpoint(5999, "tcp", [meter(4, "elite_440")])]))

      {elsewhere, log} =
        with_log(fn ->
          elsewhere = Intake.offer(elsewhere, [job(%{"request_id" => @other})], @now)
          refute_receive {:recorded, [%{request_id: @other} | _]}, 300
          elsewhere
        end)

      assert log =~ "\"SIM-3\" not read or configured"
      intake = Intake.configured(elsewhere, config!([chain(port)]))

      intake = Intake.offer(intake, [job()], @now)
      assert [%Reading{unit_id: 3, request_id: @id} | _] = requested!()
      Intake.offer(intake, [job(%{"request_id" => @other})], @now)
      refute_receive {:recorded, [%{request_id: @other} | _]}, 300
    end
  end
end
