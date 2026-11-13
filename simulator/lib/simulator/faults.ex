defmodule Simulator.Faults do
  @moduledoc """
  Faults the simulated endpoint injects. All off by default.

  - `busy`: every request gets exception 06, server device busy.
  - `noise`: bytes sent before each RTU response, like a stray byte at RS-485
    bus turnaround. Modbus TCP responses are unaffected.
  """

  defstruct silent_units: MapSet.new(), busy: false, bad_crc: false, delay_ms: 0, noise: <<>>

  @type t :: %__MODULE__{
          silent_units: MapSet.t(1..247),
          busy: boolean(),
          bad_crc: boolean(),
          delay_ms: non_neg_integer(),
          noise: binary()
        }
end
