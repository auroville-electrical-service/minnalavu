defmodule Alavi.Status.PageTest do
  use ExUnit.Case, async: true

  alias Alavi.Status.{Page, Snapshot}
  alias Alavi.StatusFixture

  # The summary's budget at 1,500 meters, whatever their state; see `render/2`'s tests.
  @budget 64 * 1024

  defp summary(meters, opts \\ []),
    do: meters |> StatusFixture.snapshot(5, opts) |> Page.render(5)

  defp section(html, heading) do
    [_before, rest] = String.split(html, "<h2>#{heading}</h2>", parts: 2)
    rest |> String.split("<h2>", parts: 2) |> hd()
  end

  describe "render/2" do
    # 1,500 meters on 300 endpoints: 64 KB every 5 s is 13 KB/s on loopback, about a
    # thirtieth of what one page with every endpoint in full weighed; the margin is
    # for raw-bytes lines (50 kept) and longer hosts than the fixture's.
    test "stays within its budget at 1,500 meters, healthy or failing" do
      every = Enum.to_list(1..300)

      for opts <- [[], [down: every], [missing: for(n <- every, u <- 2..5, do: {n, u})]] do
        size = byte_size(summary(1_500, opts))
        assert size <= @budget, "#{size} bytes with #{inspect(Keyword.keys(opts))}"
      end
    end

    test "lists an endpoint down and a meter missed under Not OK, linked to their pages" do
      html = summary(25, down: [2], missing: [{4, 3}])
      not_ok = section(html, "Not OK")

      assert not_ok =~ ~s|<a href="/endpoint/2">#{StatusFixture.host(2)}:502</a></td><td>down|
      assert not_ok =~ "missed (timeout): units 1, 2, 3, 4, 5"
      assert not_ok =~ ~s|<a href="/endpoint/4">#{StatusFixture.host(4)}:502</a>|
      assert not_ok =~ "some units not OK"
      assert not_ok =~ "missed (timeout): unit 3<"
      refute not_ok =~ "/endpoint/1\""
    end

    test "counts endpoints and meters by state, and links the healthy ones only" do
      html = summary(25, down: [2], missing: [{4, 3}])
      counts = section(html, "Endpoints and meters")

      assert counts =~
               ~s|<td>5</td><td>3</td><td><span class="bad">1</span></td><td><span class="bad">1</span></td><td>0</td>|

      assert counts =~
               ~s|<td>25</td><td>19</td><td>0</td><td><span class="bad">6</span></td><td>0</td>|

      healthy = section(html, "Endpoints OK or not polled yet")
      for n <- [1, 3, 5], do: assert(healthy =~ ~s|href="/endpoint/#{n}"|)
      for n <- [2, 4], do: refute(healthy =~ ~s|href="/endpoint/#{n}"|)
      refute html =~ "<h3>Unit"
      refute html =~ "123456.789"
    end

    test "says so when nothing is wrong" do
      assert section(summary(10), "Not OK") =~ "Every endpoint polled so far read every meter"
    end

    test "marks batches refused, discarded or quarantined" do
      backlog = %{
        events: 0,
        bytes: 0,
        batches: 0,
        oldest: nil,
        max_bytes: 100,
        refused: 2,
        discarded_files: 0,
        quarantined: 1
      }

      html = 5 |> StatusFixture.snapshot() |> Snapshot.backlog(backlog, ~U[2026-11-14 10:00:00Z])
      html = Page.render(html, 5)

      assert html =~ ~s|<th>quarantined</th><td><span class="bad">1</span>|
      assert html =~ ~s|<th>refused</th><td><span class="bad">2</span>|
      assert html =~ ~s|<th>discarded_files</th><td>0</td>|
    end
  end

  describe "endpoint/3" do
    test "shows the endpoint's rounds, failures and meters with their register values" do
      snapshot = StatusFixture.snapshot(10, 5, missing: [{1, 2}])
      {:ok, html} = Page.endpoint(snapshot, 1, 5)
      e = hd(snapshot.endpoints)

      assert html =~ ~s|<meta http-equiv="refresh" content="5">|
      assert html =~ ~s|<a href="/">Back to the summary</a>|
      assert html =~ "<h1>alavi endpoint #{StatusFixture.host(1)}:502</h1>"
      assert html =~ "<th>Framing</th><td>tcp</td>"
      assert html =~ "<th>Polled by another system</th><td>false</td>"

      rounds = section(html, "Last rounds")
      assert length(Regex.scan(~r/<tr><td>2026-11-14T/, rounds)) == 10

      assert rounds =~
               ~s|<span class="ok">unit 1 ok</span> <span class="bad">unit 2 missed (timeout)</span>|

      failures = section(html, "Recent failures")
      assert length(Regex.scan(~r/<tr><td>2026/, failures)) == 20

      assert failures =~
               ~s|<td>2</td><td><span class="note">none</span></td><td>active_energy_import</td><td><span class="bad">timeout</span></td>|

      meters = section(html, "Meters")

      for m <- e.meters do
        assert meters =~ "<h3>Unit #{m.unit_id}: #{m.profile}</h3>"
        assert meters =~ "<th>Serial expected</th><td>#{m.serial_expected}</td>"

        for r <- m.registers do
          assert meters =~ "<td>#{r.key}</td>"
          assert meters =~ "<td>#{r.source}</td>"
        end
      end

      assert meters =~ ~s|<th>Serial read</th><td><span class="ok">SIM-1</span>|
      assert meters =~ "<th>Product code read</th><td>ELITE440-445</td>"

      assert meters =~
               "<th>Firmware read</th><td>SIM-SW / SIM-F1 / SIM-F2 / 0100 at 2026-11-14T10:00:00Z"

      assert meters =~ ~s|<th>Missed reads since start</th><td><span class="bad">40</span>|

      assert meters =~
               ~s|<span class="mono">123456.789</span></td><td>kWh</td><td>2026-11-14T10:00:00Z</td>|

      assert meters =~ ~s|<th>Last round</th><td><span class="bad">missed</span>|
    end

    test "shows each meter's request latency, a meter not asked yet left out" do
      summary = %{since: ~D[2026-11-08], answered: 1_440, retries: 2, timeouts: 3}
      endpoint = %{host: StatusFixture.host(1), port: 502}
      by_unit = %{1 => Map.merge(summary, %{p50: 40, p90: 50, p99: 80, max: 75}), 2 => nil}

      by_unit =
        Map.put(
          by_unit,
          3,
          %{summary | answered: 0, retries: 0, timeouts: 0} |> Map.merge(no_figures())
        )

      snapshot = 10 |> StatusFixture.snapshot(5) |> Snapshot.latency(endpoint, by_unit)
      {:ok, html} = Page.endpoint(snapshot, 1, 5)
      latency = section(html, "Request latency")

      assert latency =~
               "<tr><td>1</td><td>2026-11-08</td><td>1440</td><td>2</td>" <>
                 ~s|<td><span class="warn">3</span></td>| <>
                 "<td>40</td><td>50</td><td>80</td><td>75</td></tr>"

      assert latency =~ "<tr><td>3</td><td>2026-11-08</td><td>0</td><td>0</td><td>0</td>"
      assert latency =~ ~s|<td><span class="note">none</span></td></tr>|
      refute latency =~ "<tr><td>2</td>"

      {:ok, html} = Page.endpoint(StatusFixture.snapshot(10), 1, 5)
      assert section(html, "Request latency") =~ "No request yet."
    end

    test "is :error for an endpoint the config does not have" do
      snapshot = StatusFixture.snapshot(10)
      assert {:ok, _} = Page.endpoint(snapshot, 2, 5)
      assert Page.endpoint(snapshot, 3, 5) == :error
    end
  end

  defp no_figures, do: %{p50: nil, p90: nil, p99: nil, max: nil}
end
