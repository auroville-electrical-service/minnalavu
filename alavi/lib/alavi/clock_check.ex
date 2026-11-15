defmodule Alavi.ClockCheck do
  @moduledoc """
  One SNTP query to an NTP server and what came of it, as `Alavi.Clock.Check`
  made it: the four times as measured, never an offset (the store computes
  offsets). `t1` is when the collector sent the query, or tried to; `t4` when
  it received the reply, or gave up. An answer carries the server's `t2`
  (received) and `t3` (sent) as `Alavi.Sntp` times, and the address that
  replied; a kiss-o'-death that address and its kiss code.
  """

  alias Alavi.Sntp

  @enforce_keys [:trigger, :server, :t1, :t4, :outcome]
  defstruct @enforce_keys

  @type trigger :: :start | :daily | :step

  @type answer :: %{
          address: :inet.ip_address(),
          stratum: 1..15,
          leap: 0..2,
          reference_id: non_neg_integer(),
          t2: Sntp.time(),
          t3: Sntp.time()
        }

  @type outcome ::
          {:answered, answer()}
          | :timeout
          | :unreachable
          | {:kiss_of_death, :inet.ip_address(), non_neg_integer()}
          | :invalid

  @typedoc "`server` is as configured: a name or an address."
  @type t :: %__MODULE__{
          trigger: trigger(),
          server: String.t(),
          t1: DateTime.t(),
          t4: DateTime.t(),
          outcome: outcome()
        }

  # contract: test/alavi/wire_test.exs "ClockCheck.to_wire/1"
  @spec to_wire(t()) :: %{String.t() => term()}
  def to_wire(%__MODULE__{} = c) do
    %{
      "trigger" => Atom.to_string(c.trigger),
      "server" => c.server,
      "outcome" => c.outcome |> outcome() |> Atom.to_string(),
      "t1" => DateTime.to_iso8601(c.t1),
      "t4" => DateTime.to_iso8601(c.t4)
    }
    |> Map.merge(reply(c.outcome))
  end

  # contract: test/alavi/status_test.exs "Snapshot.clock_check/2"
  @doc """
  The offset of the server's clock from the collector's an answer implies,
  ((t2 − t1) + (t3 − t4)) / 2, in whole milliseconds toward zero; nil for any
  other outcome. For display only: it is never sent.
  """
  @spec offset_ms(t()) :: integer() | nil
  def offset_ms(%__MODULE__{outcome: {:answered, a}} = c) do
    t1 = DateTime.to_unix(c.t1, :nanosecond)
    t4 = DateTime.to_unix(c.t4, :nanosecond)
    div(a.t2 - t1 + (a.t3 - t4), 2_000_000)
  end

  def offset_ms(%__MODULE__{}), do: nil

  @spec outcome(outcome()) :: :answered | :timeout | :unreachable | :kiss_of_death | :invalid
  def outcome({:answered, _answer}), do: :answered
  def outcome({:kiss_of_death, _address, _code}), do: :kiss_of_death
  def outcome(outcome) when outcome in [:timeout, :unreachable, :invalid], do: outcome

  defp reply({:answered, a}) do
    %{
      "t2" => Sntp.rfc3339(a.t2),
      "t3" => Sntp.rfc3339(a.t3),
      "address" => address(a.address),
      "stratum" => a.stratum,
      "leap" => a.leap,
      "reference_id" => a.reference_id
    }
  end

  defp reply({:kiss_of_death, address, code}),
    do: %{"address" => address(address), "reference_id" => code}

  defp reply(_outcome), do: %{}

  defp address(ip), do: ip |> :inet.ntoa() |> to_string()
end
