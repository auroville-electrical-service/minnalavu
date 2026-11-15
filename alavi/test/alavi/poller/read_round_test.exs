defmodule Alavi.Poller.ReadRoundTest do
  @moduledoc """
  `contract/fixtures/read-round.v1.json`, through the poller: each case's
  meters polled for one round on an endpoint that answers as its steps say.
  Firmware names are left out of the round, as the fixture leaves them out.
  """
  use ExUnit.Case, async: true

  import Alavi.PollerCase

  alias Alavi.{MissedRead, Reading, ScriptedEndpoint}

  @moduletag :capture_log
  @fixture Path.expand("../../../../contract/fixtures/read-round.v1.json", __DIR__)
  @external_resource @fixture
  %{"format" => "read-round/1"} = fixture = @fixture |> File.read!() |> JSON.decode!()
  @policy fixture["policy"]
  @failures %{
    "timeout" => :timeout,
    "closed" => :closed,
    "malformed_response" => :malformed_response
  }

  for c <- fixture["cases"] do
    @tag case: c
    test c["why"], %{case: c} do
      port = c["steps"] |> Enum.map(&entry(&1["event"])) |> ScriptedEndpoint.start!()
      poll!(port, c["meters"])

      events = c["meters"] |> Enum.flat_map(fn _meter -> recorded!() end) |> Enum.map(&wire/1)
      assert events == Enum.map(c["events"], &refused/1)

      sent = for s <- c["steps"], not Map.has_key?(s["event"], "unreachable"), do: s
      reads = for _step <- sent, do: assert_receive({:scripted_read, _read, _gap})

      assert Enum.map(reads, fn {:scripted_read, read, _gap} -> read end) ==
               Enum.map(sent, & &1["read"])

      refute_receive {:scripted_read, _read, _gap}, 100

      for {{:scripted_read, _read, gap}, %{"wait_ms" => wait}} <- Enum.zip(reads, sent),
          do: assert(gap >= wait)
    end
  end

  defp poll!(port, meters) do
    changes = %{
      "timeout_ms" => 50,
      "retries" => @policy["retries"],
      "busy_backoff_ms" => @policy["busy_backoff_ms"]
    }

    config =
      config!([
        endpoint(port, "tcp", Enum.map(meters, &Map.take(&1, ~w(unit_id profile))), changes)
      ])

    opts = [
      config: without_names(config),
      sink: {Alavi.TestSink, self()},
      clock: &DateTime.utc_now/0,
      raw_log: raw_log(),
      status: no_status(),
      selectors_dir: selectors_dir!()
    ]

    start_supervised!({Alavi.Pollers, opts})
  end

  defp without_names(config) do
    endpoints =
      for e <- config.endpoints do
        %{e | meters: for(m <- e.meters, do: %{m | profile: %{m.profile | firmware: nil}})}
      end

    %{config | endpoints: endpoints}
  end

  defp entry(%{"words" => words}), do: {:words, words}
  defp entry(%{"exception" => code}), do: {:exception, code}
  defp entry(%{"failed" => failure}), do: Map.fetch!(@failures, failure)
  defp entry(%{"unreachable" => _detail}), do: :unreachable

  @reading ~w(unit_id register_key meter_serial product_code value)
  @missed ~w(unit_id register_key meter_serial reason exception_code detail attempts raw_words)

  defp wire(%Reading{} = r), do: %{"reading" => r |> Reading.to_wire() |> Map.take(@reading)}
  defp wire(%MissedRead{} = m), do: %{"missed" => m |> MissedRead.to_wire() |> Map.take(@missed)}

  # Windows times out a refused connect where Linux and macOS refuse it.
  defp refused(%{"missed" => %{"reason" => "unreachable"} = m}),
    do: %{"missed" => %{m | "detail" => Atom.to_string(refused())}}

  defp refused(event), do: event
end
