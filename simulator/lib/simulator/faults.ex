defmodule Simulator.Faults do
  @moduledoc """
  Faults the simulated endpoint injects. All off by default.

  - `silent_units`: requests for these units go unanswered.
  - `silent_reads`: requests that start at one of these `{unit_id, address}`
    go unanswered; the unit's other reads are answered.
  - `refused_reads`: requests that start at one of these `{unit_id, address}`
    get the exception code mapped to it.
  - `refused_spans`: read requests for exactly these
    `{unit_id, address, count}` get the exception code mapped to it, and
    other reads from the same address are answered: a gateway answering
    exception 11 for a merged read the meter stays silent for.
  - `two_byte_replies`: requests for these units get the PDU `0B` alone, the
    gateway exception code with no function code, as some Modbus TCP
    gateways send, framed under the unit byte mapped to the unit, which need
    not be the unit asked for.
  - `lost_writes`: a selector write to one of these `{unit_id, address}` is
    echoed but not applied, so the selector reads back what it held. No meter
    has been seen doing this; it stands for a write another client undid at
    once, which is what reading a selector back after writing it is for.
  - `refused_writes`: a selector write to one of these `{unit_id, address}`
    gets the exception code mapped to it and is not applied; reads there are
    answered.
  - `dropped_requests`: a request that starts at one of these
    `{unit_id, address}`, read or write, closes the connection unanswered,
    as a gateway that drops its link mid-copy.
  - `busy`: every request gets exception 06, server device busy.
  - `noise`: bytes sent before each RTU response, like a stray byte at RS-485
    bus turnaround. Modbus TCP responses are unaffected.
  """

  defstruct silent_units: MapSet.new(),
            silent_reads: MapSet.new(),
            refused_reads: %{},
            refused_spans: %{},
            two_byte_replies: %{},
            lost_writes: MapSet.new(),
            refused_writes: %{},
            dropped_requests: MapSet.new(),
            busy: false,
            bad_crc: false,
            delay_ms: 0,
            noise: <<>>

  @type t :: %__MODULE__{
          silent_units: MapSet.t(1..247),
          silent_reads: MapSet.t({1..247, 0..0xFFFF}),
          refused_reads: %{optional({1..247, 0..0xFFFF}) => 1..255},
          refused_spans: %{optional({1..247, 0..0xFFFF, 1..125}) => 1..255},
          two_byte_replies: %{optional(1..247) => 0..255},
          lost_writes: MapSet.t({1..247, 0..0xFFFF}),
          refused_writes: %{optional({1..247, 0..0xFFFF}) => 1..255},
          dropped_requests: MapSet.t({1..247, 0..0xFFFF}),
          busy: boolean(),
          bad_crc: boolean(),
          delay_ms: non_neg_integer(),
          noise: binary()
        }
end
