defmodule Alavi.Selectors.Store do
  @moduledoc """
  An endpoint's selector records on disk (`Alavi.Selectors.Record`), two
  files per endpoint in one directory:

  - `<endpoint>.restore`, the owed restore: created once, exclusively, and
    synced before a session's first write; deleted only once every value has
    been read back. It is never renamed or replaced, so no platform's rename
    is relied on, and a crash leaves it absent, whole, or torn: a torn one is
    unreadable, which is owed with values unknown, never nothing owed.
  - `<endpoint>.left`, what was left: replaced by writing `<endpoint>.left.new`
    whole and synced, then renaming it over. A rename over an existing file
    need not be atomic (on Windows OTP may delete the old file first), so
    while a `.new` file exists that reads whole, it is the newer, and one
    that does not read whole was never renamed and is passed over.

  The directory itself is not synced: OTP cannot open a directory to sync it.
  """

  require Logger

  alias Alavi.Selectors.Record

  @owed ".restore"
  @left ".left"
  @new ".new"

  @type unreadable :: {:unreadable, Path.t(), String.t()}

  # contract: test/alavi/selectors/store_test.exs "owed/2"
  @spec owed(Path.t(), Record.endpoint()) :: :none | {:ok, Record.t()} | {:error, unreadable()}
  def owed(dir, endpoint) do
    path = path(dir, endpoint, @owed)

    case File.read(path) do
      {:ok, text} -> parsed(Record.parse(text, endpoint), path)
      {:error, :enoent} -> :none
      {:error, reason} -> {:error, {:unreadable, path, format(reason)}}
    end
  end

  # contract: test/alavi/selectors/store_test.exs "owe/2"
  @doc "Never replaces a record: one already owed is `:owed`."
  @spec owe(Path.t(), Record.t()) :: :ok | {:error, :owed | {:file, File.posix()}}
  def owe(dir, %Record{endpoint: endpoint} = record) do
    path = path(dir, endpoint, @owed)

    with :ok <- mkdir(dir) do
      case :file.open(path, [:write, :exclusive, :binary, :raw]) do
        {:ok, fd} -> written(fd, path, Record.encode(record))
        {:error, :eexist} -> {:error, :owed}
        {:error, reason} -> {:error, {:file, reason}}
      end
    end
  end

  # contract: test/alavi/selectors/store_test.exs "owe/2"
  @spec clear(Path.t(), Record.endpoint()) :: :ok | {:error, {:file, File.posix()}}
  def clear(dir, endpoint) do
    case File.rm(path(dir, endpoint, @owed)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:file, reason}}
    end
  end

  # contract: test/alavi/selectors/store_test.exs "left/2"
  @spec left(Path.t(), Record.endpoint()) :: {:ok, Record.left()} | {:error, unreadable()}
  def left(dir, endpoint) do
    path = path(dir, endpoint, @left)

    case read_new(path <> @new, endpoint) do
      {:ok, left} -> {:ok, left}
      :none -> read_left(path, endpoint)
    end
  end

  # contract: test/alavi/selectors/store_test.exs "left/2"
  @doc "Merges `values` into what was left; one that cannot be read is not replaced."
  @spec leave(Path.t(), Record.endpoint(), Record.left()) ::
          :ok | {:error, unreadable() | {:file, File.posix()}}
  def leave(dir, endpoint, values) do
    path = path(dir, endpoint, @left)

    with {:ok, left} <- left(dir, endpoint),
         :ok <- mkdir(dir),
         {:ok, fd} <- file(:file.open(path <> @new, [:write, :binary, :raw])),
         :ok <- written(fd, path <> @new, Record.encode_left(endpoint, Map.merge(left, values))) do
      file(:file.rename(path <> @new, path))
    end
  end

  defp read_new(path, endpoint) do
    with {:ok, text} <- File.read(path),
         {:ok, left} <- Record.parse_left(text, endpoint) do
      {:ok, left}
    else
      {:error, :enoent} ->
        :none

      {:error, why} ->
        Logger.warning(
          "alavi selectors: #{path} does not read whole (#{inspect(why)}); passed over"
        )

        :none
    end
  end

  defp read_left(path, endpoint) do
    case File.read(path) do
      {:ok, text} -> parsed(Record.parse_left(text, endpoint), path)
      {:error, :enoent} -> {:ok, %{}}
      {:error, reason} -> {:error, {:unreadable, path, format(reason)}}
    end
  end

  defp parsed({:ok, value}, _path), do: {:ok, value}
  defp parsed({:error, why}, path), do: {:error, {:unreadable, path, why}}

  # A file not written whole is removed; if that fails too, it stays, unreadable.
  defp written(fd, path, data) do
    with :ok <- :file.write(fd, data),
         :ok <- :file.sync(fd) do
      file(:file.close(fd))
    else
      {:error, reason} ->
        _ = :file.close(fd)
        _ = File.rm(path)
        {:error, {:file, reason}}
    end
  end

  defp mkdir(dir), do: file(File.mkdir_p(dir))

  defp file(:ok), do: :ok
  defp file({:ok, fd}), do: {:ok, fd}
  defp file({:error, reason}), do: {:error, {:file, reason}}

  defp format(reason), do: reason |> :file.format_error() |> to_string()

  # Host characters a file name may not hold, on Windows above all, become `_`;
  # the record names its endpoint, so two that map to one name cannot be confused.
  defp path(dir, %{host: host, port: port}, suffix),
    do: Path.join(dir, String.replace(host, ~r/[^A-Za-z0-9.-]/, "_") <> "_#{port}" <> suffix)
end
