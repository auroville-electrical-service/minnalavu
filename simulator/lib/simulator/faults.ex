defmodule Simulator.Faults do
  @moduledoc """
  Faults the simulated endpoint injects. All off by default.

  - `silent_units`: requests for these units go unanswered.
  - `silent_reads`: requests that start at one of these `{unit_id, address}`
    go unanswered; the unit's other reads are answered.
  - `refused_reads`: requests that start at one of these `{unit_id, address}`
    get the exception code mapped to it.
  - `busy`: every request gets exception 06, server device busy.
  - `noise`: bytes sent before each RTU response, like a stray byte at RS-485
    bus turnaround. Modbus TCP responses are unaffected.
  """

  defstruct silent_units: MapSet.new(),
            silent_reads: MapSet.new(),
            refused_reads: %{},
            busy: false,
            bad_crc: false,
            delay_ms: 0,
            noise: <<>>

  @type t :: %__MODULE__{
          silent_units: MapSet.t(1..247),
          silent_reads: MapSet.t({1..247, 0..0xFFFF}),
          refused_reads: %{optional({1..247, 0..0xFFFF}) => 1..255},
          busy: boolean(),
          bad_crc: boolean(),
          delay_ms: non_neg_integer(),
          noise: binary()
        }
end
