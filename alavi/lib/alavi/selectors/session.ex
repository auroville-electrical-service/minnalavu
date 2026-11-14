defmodule Alavi.Selectors.Session do
  @moduledoc """
  The only way the collector writes to a meter: a session on one meter of an
  endpoint, over the endpoint's one connection, which writes only the
  selectors it was opened on, and only once their values are saved to
  disk (`Alavi.Selectors.Store`) to be put back.

  `open/6` reads each selector, refuses if one is not at the value the last
  session left it at, then saves the values read. `set/5` writes one and
  reads it back. `close/2` puts them back. `restore/3` does the same from
  the saved record alone, after a crash or a failed close: it writes back
  each selector not at its saved value, reads every one back, and only when
  all match records them as left and deletes the record. Until then a
  restore is owed, and no session opens on the endpoint.

  Each write is one `Alavi.Modbus.Client.write_selector/3`, never retried
  here; a failure is returned, the record stays, and the restore is the
  caller's to retry. Reads are single attempts too.
  """

  require Logger

  alias Alavi.Modbus.{Client, Selector}
  alias Alavi.Selectors.{Record, Store}

  @enforce_keys [:dir, :record]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{dir: Path.t(), record: Record.t()}

  @type read_error :: {:read, Selector.name(), Client.error()}
  @type open_error ::
          :not_allowed
          | :restore_owed
          | {:left_unreadable, Store.unreadable()}
          | read_error()
          | {:moved, Selector.name(), read :: 0..0xFFFF, left :: 0..0xFFFF}
          | {:not_restorable, Selector.name(), 0..0xFFFF}
          | {:store, :owed | {:file, File.posix()}}
  @type write_error ::
          :not_allowed
          | :out_of_range
          | {:write, Selector.name(), Client.write_error()}
          | read_error()
          | {:read_back, Selector.name(), expected :: 0..0xFFFF, read :: 0..0xFFFF}
  @type set_error :: :not_in_session | :not_owed | write_error()
  @type restore_error ::
          {:unreadable, Store.unreadable()}
          | write_error()
          | {:store, Store.unreadable() | {:file, File.posix()}}

  # contract: test/alavi/selectors/session_test.exs "open/6"
  @doc "`selectors`: each selector the session may write, with the bound its value is checked against."
  @spec open(
          Client.t(),
          Path.t(),
          Record.endpoint(),
          1..247,
          Selector.model(),
          [{Selector.name(), integer()}, ...]
        ) :: {:ok, t(), Client.t()} | {:error, open_error(), Client.t()}
  def open(client, dir, endpoint, unit, model, selectors) do
    names = Enum.map(selectors, &elem(&1, 0))

    with :ok <- allowed(model, names),
         :none <- Store.owed(dir, endpoint),
         {:ok, left} <- left(dir, endpoint) do
      record = %Record{endpoint: endpoint, unit_id: unit, model: model, selectors: []}
      found(read_all(client, record, selectors), left, dir)
    else
      {:ok, %Record{}} -> refused(endpoint, unit, :restore_owed, client)
      {:error, {:unreadable, _path, _why}} -> refused(endpoint, unit, :restore_owed, client)
      {:error, reason} -> refused(endpoint, unit, reason, client)
    end
  end

  # contract: test/alavi/selectors/session_test.exs "set/5"
  @doc "Write `name` to `value` and read it back; `bound` as for `Alavi.Modbus.Selector.request/4`."
  @spec set(t(), Client.t(), Selector.name(), integer(), integer()) ::
          {:ok, Client.t()} | {:error, set_error(), Client.t()}
  def set(%__MODULE__{dir: dir, record: record}, client, name, value, bound) do
    cond do
      not Enum.any?(record.selectors, &(&1.name == name)) -> {:error, :not_in_session, client}
      Store.owed(dir, record.endpoint) != {:ok, record} -> {:error, :not_owed, client}
      true -> put(client, record, name, value, bound)
    end
  end

  # contract: test/alavi/selectors/session_test.exs "restore/3"
  @spec close(t(), Client.t()) ::
          {:ok, :restored, Client.t()} | {:error, restore_error(), Client.t()}
  def close(%__MODULE__{dir: dir, record: record}, client), do: put_back(client, dir, record)

  # contract: test/alavi/selectors/session_test.exs "restore/3"
  @doc "`:none` when nothing is owed on the endpoint."
  @spec restore(Client.t(), Path.t(), Record.endpoint()) ::
          {:ok, :none | :restored, Client.t()} | {:error, restore_error(), Client.t()}
  def restore(client, dir, endpoint) do
    case Store.owed(dir, endpoint) do
      :none -> {:ok, :none, client}
      {:ok, record} -> put_back(client, dir, record)
      {:error, unreadable} -> {:error, {:unreadable, unreadable}, client}
    end
  end

  defp allowed(model, names) do
    known = for e <- Selector.allowlist(), e.model == model, do: e.name

    if names != [] and Enum.uniq(names) == names and Enum.all?(names, &(&1 in known)),
      do: :ok,
      else: {:error, :not_allowed}
  end

  defp left(dir, endpoint) do
    case Store.left(dir, endpoint) do
      {:ok, left} -> {:ok, left}
      {:error, unreadable} -> {:error, {:left_unreadable, unreadable}}
    end
  end

  defp read_all(client, record, selectors) do
    Enum.reduce_while(selectors, {:ok, record, client}, fn {name, bound}, {:ok, record, client} ->
      case read(client, record, name) do
        {:ok, value, client} ->
          found = %{name: name, value: value, bound: bound}
          {:cont, {:ok, %{record | selectors: record.selectors ++ [found]}, client}}

        {:error, reason, client} ->
          {:halt, {:error, reason, client}}
      end
    end)
  end

  defp found({:ok, record, client}, left, dir) do
    with :ok <- unmoved(record, left),
         :ok <- restorable(record),
         :ok <- owe(dir, record) do
      {:ok, %__MODULE__{dir: dir, record: record}, client}
    else
      {:error, reason} -> refused(record.endpoint, record.unit_id, reason, client)
    end
  end

  defp found({:error, reason, client}, _left, _dir), do: {:error, reason, client}

  # A selector not where the last session left it means another client is
  # using the meter, or has used it and left it moved.
  defp unmoved(%Record{unit_id: unit, model: model, selectors: selectors}, left) do
    case Enum.find(selectors, &(Map.get(left, {unit, model, &1.name}, &1.value) != &1.value)) do
      nil -> :ok
      s -> {:error, {:moved, s.name, s.value, left[{unit, model, s.name}]}}
    end
  end

  # A value the allowlist would not let us write back is never moved from.
  defp restorable(%Record{model: model, selectors: selectors}) do
    case Enum.find(
           selectors,
           &(Selector.request(model, &1.name, &1.value, &1.bound) |> failed?())
         ) do
      nil -> :ok
      s -> {:error, {:not_restorable, s.name, s.value}}
    end
  end

  defp failed?({:ok, _request}), do: false
  defp failed?({:error, _reason}), do: true

  defp owe(dir, record) do
    case Store.owe(dir, record) do
      :ok -> :ok
      {:error, reason} -> {:error, {:store, reason}}
    end
  end

  defp refused(%{host: host, port: port}, unit, reason, client) do
    Logger.warning(
      "alavi selectors #{host}:#{port} unit #{unit}: no session opened, nothing written: " <>
        inspect(reason)
    )

    {:error, reason, client}
  end

  defp put(client, record, name, value, bound) do
    case Selector.request(record.model, name, value, bound) do
      {:ok, request} ->
        client
        |> Client.write_selector(record.unit_id, request)
        |> wrote(record, name, value)

      {:error, reason} ->
        {:error, reason, client}
    end
  end

  defp wrote({:ok, client}, record, name, value), do: read_back(client, record, name, value)

  defp wrote({:error, reason, client}, _record, name, _value),
    do: {:error, {:write, name, reason}, client}

  defp read_back(client, record, name, expected) do
    case read(client, record, name) do
      {:ok, ^expected, client} -> {:ok, client}
      {:ok, value, client} -> {:error, {:read_back, name, expected, value}, client}
      {:error, reason, client} -> {:error, reason, client}
    end
  end

  defp put_back(client, dir, record) do
    with {:ok, client} <- each(client, record, &unless_at(&1, record, &2)),
         {:ok, client} <- each(client, record, &read_back(&1, record, &2.name, &2.value)) do
      recorded(client, dir, record)
    end
  end

  # The selectors not at their saved value are written back.
  defp unless_at(client, record, %{name: name, value: value, bound: bound}) do
    case read(client, record, name) do
      {:ok, ^value, client} -> {:ok, client}
      {:ok, _other, client} -> put(client, record, name, value, bound)
      {:error, reason, client} -> {:error, reason, client}
    end
  end

  defp each(client, record, step) do
    Enum.reduce_while(record.selectors, {:ok, client}, fn selector, {:ok, client} ->
      case step.(client, selector) do
        {:ok, client} -> {:cont, {:ok, client}}
        {:error, _reason, _client} = error -> {:halt, error}
      end
    end)
  end

  defp recorded(client, dir, record) do
    with :ok <- Store.leave(dir, record.endpoint, Record.left(record)),
         :ok <- Store.clear(dir, record.endpoint) do
      {:ok, :restored, client}
    else
      {:error, reason} -> {:error, {:store, reason}, client}
    end
  end

  defp read(client, %Record{unit_id: unit, model: model}, name) do
    %{address: address} =
      Enum.find(Selector.allowlist(), &(&1.model == model and &1.name == name))

    case Client.read(client, unit, :holding, address, 1) do
      {:ok, [value], client} -> {:ok, value, client}
      {:error, reason, client} -> {:error, {:read, name, reason}, client}
    end
  end
end
