defmodule Alavi.Copy.Run do
  @moduledoc """
  One night's copy of an endpoint's meters, and how far it has got: the
  poller runs one phase of it per step (`Alavi.Copy.Copier`). Per meter, a
  visit: its identity and clock, then per store a selector session opened,
  its stamps scanned newest first, the entries due copied one per step, and
  the session closed; then its clock again.

  A run asked to stop (`stop/2`) stops at an entry boundary: a session open
  is closed first, and the visit's clock read, before it is done.
  """

  alias Alavi.Config.Meter
  alias Alavi.Copy.{Progress, Stores}
  alias Alavi.Profile.Stored
  alias Alavi.Selectors.Session

  @enforce_keys [:meters, :phase, :stop, :fault]
  defstruct @enforce_keys

  @typedoc "Why a run stopped before its meters were done."
  @type stop :: :window | :retiring

  @typedoc "A meter visited: what it reported, its progress so far and the stores left."
  @type visit :: %{
          meter: Meter.t(),
          serial: String.t(),
          product_code: String.t(),
          progress: Progress.t(),
          clock: [0..0xFFFF],
          stores: [Stores.store()]
        }

  @typedoc """
  A store with its session open: what the meter holds (`available`, the
  load survey's `mask`, interval and `parameters`), the slots left to scan
  and what the scan `found`, the entries `due`, `done` of `of`, and the day
  the load survey's day selector shows. `connection` is the poller's
  connection the session was opened on.
  """
  @type scope :: %{
          store: Stores.store(),
          session: Session.t(),
          connection: non_neg_integer(),
          available: non_neg_integer(),
          mask: non_neg_integer() | nil,
          interval: [0..0xFFFF] | nil,
          parameters: [Stored.parameter()] | nil,
          slots: [Stores.slot()],
          found: [{Stores.slot(), NaiveDateTime.t()}],
          due: [Stores.item()],
          done: non_neg_integer(),
          of: non_neg_integer(),
          day: Stores.slot() | nil,
          rescans: non_neg_integer()
        }

  @type phase ::
          {:visit, Meter.t()}
          | {:open, visit()}
          | {:scan, visit(), scope()}
          | {:copy, visit(), scope()}
          | {:close, visit(), scope()}
          | {:end_visit, visit()}
          | :done

  @typedoc "`fault`: the run ended with a restore owed."
  @type t :: %__MODULE__{
          meters: [Meter.t()],
          phase: phase(),
          stop: stop() | nil,
          fault: boolean()
        }

  # contract: test/alavi/copy/run_test.exs "new/1"
  @spec new([Meter.t()]) :: t()
  def new(meters),
    do: next_meter(%__MODULE__{meters: meters, phase: :done, stop: nil, fault: false})

  # contract: test/alavi/copy/run_test.exs "new/1"
  @doc "Stop at the next entry boundary; the first reason given stands."
  @spec stop(t(), stop()) :: t()
  def stop(%__MODULE__{stop: nil} = run, why), do: %{run | stop: why, phase: halted(run.phase)}
  def stop(%__MODULE__{} = run, _why), do: run

  # contract: test/alavi/copy/run_test.exs "new/1"
  @doc "On to the next meter's visit, or done: no visit starts once the run is stopping."
  @spec next_meter(t()) :: t()
  def next_meter(%__MODULE__{stop: nil, meters: [meter | rest]} = run),
    do: %{run | meters: rest, phase: {:visit, meter}}

  def next_meter(%__MODULE__{} = run), do: %{run | meters: [], phase: :done}

  @doc "Ended by a lost connection or a failed close: a restore is owed."
  @spec faulted(t()) :: t()
  def faulted(%__MODULE__{} = run), do: %{run | meters: [], phase: :done, fault: true}

  @spec done?(t()) :: boolean()
  def done?(%__MODULE__{phase: phase}), do: phase == :done

  @doc "How the run ended: done, stopped, or faulted."
  @spec outcome(t()) :: :done | stop() | :fault
  def outcome(%__MODULE__{fault: true}), do: :fault
  def outcome(%__MODULE__{stop: nil}), do: :done
  def outcome(%__MODULE__{stop: why}), do: why

  defp halted({:visit, _meter}), do: :done
  defp halted({:open, visit}), do: {:end_visit, visit}
  defp halted({:scan, visit, scope}), do: {:close, %{visit | stores: []}, scope}
  defp halted({:copy, visit, scope}), do: {:close, %{visit | stores: []}, scope}
  defp halted({:close, visit, scope}), do: {:close, %{visit | stores: []}, scope}
  defp halted(phase), do: phase
end
