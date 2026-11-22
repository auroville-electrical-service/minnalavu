defmodule Alavi.Copy.Run do
  @moduledoc """
  One night's copy of an endpoint's meters, and how far it has got: the
  poller runs one phase of it per step (`Alavi.Copy.Copier`). Per meter, a
  visit: its identity and clock, then per store a selector session opened,
  its stamps scanned newest first, the entries due copied one per step, and
  the session closed; then its clock again. After its nightly stores, the
  visit copies those the night's fills (`Alavi.Copy.Fill`) still owe for the
  serial the meter reported, one pass each, and `filled` collects each fill's
  meter and store that finished.

  A run asked to stop (`stop/2`) stops at an entry boundary: a session open
  is closed first, and the visit's clock read, before it is done.
  """

  alias Alavi.Config.Meter
  alias Alavi.Copy.{Fill, Progress, Stores}
  alias Alavi.Profile.Stored
  alias Alavi.Selectors.Session

  @enforce_keys [:meters, :fills, :filled, :phase, :stop, :fault, :unreached]
  defstruct @enforce_keys

  @typedoc "Why a run stopped before its meters were done."
  @type stop :: :window | :retiring

  @typedoc "A store's copy in a visit: the nightly one, from its progress, or a fill's."
  @type pass :: {Stores.store(), :nightly | Fill.t()}

  @typedoc "A meter visited: what it reported, its progress so far and the passes left."
  @type visit :: %{
          meter: Meter.t(),
          serial: String.t(),
          product_code: String.t(),
          progress: Progress.t(),
          clock: [0..0xFFFF],
          stores: [pass()]
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
          pass: :nightly | Fill.t(),
          ended: :older | :exhausted | nil,
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

  @typedoc """
  `fault`: a visit was cut short, or the run ended with a restore owed.
  `unreached`: the meters not visited because the endpoint could not be
  reached, the first of them the one whose identity read found it so.
  """
  @type t :: %__MODULE__{
          meters: [Meter.t()],
          fills: [Fill.t()],
          filled: [{String.t(), String.t(), Stores.store()}],
          phase: phase(),
          stop: stop() | nil,
          fault: boolean(),
          unreached: [Meter.t()]
        }

  # contract: test/alavi/copy/run_test.exs "new/1"
  @spec new([Meter.t()], [Fill.t()]) :: t()
  def new(meters, fills \\ []),
    do:
      next_meter(%__MODULE__{
        meters: meters,
        fills: fills,
        filled: [],
        phase: :done,
        stop: nil,
        fault: false,
        unreached: []
      })

  # contract: test/alavi/copy_test.exs "fill"
  @doc "The passes a visit makes of the meter that reported `serial`: its nightly stores, then the fills'."
  @spec passes(t(), String.t()) :: [pass()]
  def passes(%__MODULE__{fills: fills}, serial),
    do:
      Enum.map(Stores.all(), &{&1, :nightly}) ++
        for(fill <- fills, store <- Fill.due(fill, serial), do: {store, fill})

  # contract: test/alavi/copy_test.exs "fill"
  @doc "The fill `id`'s copy of `serial`'s `store` has finished."
  @spec filled(t(), String.t(), String.t(), Stores.store()) :: t()
  def filled(%__MODULE__{} = run, id, serial, store),
    do: %{run | filled: [{id, serial, store} | run.filled]}

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

  @doc "Ended with a restore owed, from a failed close or a session that cannot open until it is done."
  @spec faulted(t()) :: t()
  def faulted(%__MODULE__{} = run), do: %{run | meters: [], phase: :done, fault: true}

  # contract: test/alavi/copy_test.exs "copy"
  @doc """
  A visit cut short by a lost connection: on to the next meter. The poller
  does the restore owed first, so the next session opens on a clean meter.
  """
  @spec cut(t()) :: t()
  def cut(%__MODULE__{} = run), do: %{next_meter(run) | fault: true}

  @doc """
  The endpoint could not be reached for `meter`'s visit: the run ends, and
  `meter` and those after it are left to copy again (`unreached`).
  """
  @spec unreached(t(), Meter.t()) :: t()
  def unreached(%__MODULE__{} = run, meter),
    do: %{run | meters: [], phase: :done, unreached: [meter | run.meters]}

  @spec done?(t()) :: boolean()
  def done?(%__MODULE__{phase: phase}), do: phase == :done

  @doc """
  How the run ended: done, stopped, faulted (a visit cut short on the way),
  or with meters unreached.
  """
  @spec outcome(t()) :: :done | stop() | :fault | :unreachable
  def outcome(%__MODULE__{fault: true}), do: :fault
  def outcome(%__MODULE__{unreached: [_ | _]}), do: :unreachable
  def outcome(%__MODULE__{stop: nil}), do: :done
  def outcome(%__MODULE__{stop: why}), do: why

  defp halted({:visit, _meter}), do: :done
  defp halted({:open, visit}), do: {:end_visit, visit}
  defp halted({:scan, visit, scope}), do: {:close, %{visit | stores: []}, scope}
  defp halted({:copy, visit, scope}), do: {:close, %{visit | stores: []}, scope}
  defp halted({:close, visit, scope}), do: {:close, %{visit | stores: []}, scope}
  defp halted(phase), do: phase
end
