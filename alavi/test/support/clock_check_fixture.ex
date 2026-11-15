defmodule Alavi.ClockCheckFixture do
  @moduledoc "Clock checks of each outcome, for the tests that carry them."

  alias Alavi.ClockCheck

  @t1 ~U[2026-11-01 00:00:04.000123Z]
  @t4 ~U[2026-11-01 00:00:04.031877Z]

  @spec answered() :: ClockCheck.t()
  def answered do
    check(
      {:answered,
       %{
         address: {192, 0, 2, 123},
         stratum: 2,
         leap: 0,
         reference_id: 3_221_226_115,
         t2: 1_793_491_208_215_003_051,
         t3: 1_793_491_208_215_047_312
       }}
    )
  end

  @spec kiss_of_death() :: ClockCheck.t()
  def kiss_of_death,
    do: check({:kiss_of_death, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 0x7B}, 0x52415445})

  @spec failed(:timeout | :unreachable | :invalid) :: ClockCheck.t()
  def failed(outcome), do: check(outcome)

  defp check(outcome),
    do: %ClockCheck{trigger: :daily, server: "pool.ntp.org", t1: @t1, t4: @t4, outcome: outcome}
end
