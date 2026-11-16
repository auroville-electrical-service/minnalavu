defmodule Alavi.Copy.Progress do
  @moduledoc """
  How far each meter's stores have been copied: per store, the meter's stamp
  of the last entry copied and buffered (a load survey's, of its last day
  copied whole). One file per meter serial in one directory,
  `<serial>.copied`, replaced as `Alavi.Selectors.Store` replaces what was
  left: `<serial>.copied.new` written whole and synced, then renamed over;
  while a `.new` file exists that reads whole, it is the newer, and one that
  does not was never renamed and is passed over.

  A meter with no file has copied nothing. A file that does not read whole,
  or names another serial, is refused, never read in part.
  """

  require Logger

  alias Alavi.Copy.Stores

  @format "alavi-copy-progress.v1"
  @suffix ".copied"
  @new ".new"

  @type t :: %{optional(Stores.store()) => NaiveDateTime.t()}
  @type unreadable :: {:unreadable, Path.t(), String.t()}

  @stores %{"history" => :history, "snapshot" => :snapshot, "load_survey" => :load_survey}

  # contract: test/alavi/copy/progress_test.exs "load/2"
  @spec load(Path.t(), String.t()) :: {:ok, t()} | {:error, unreadable()}
  def load(dir, serial) do
    path = path(dir, serial)

    case read_new(path <> @new, serial) do
      {:ok, progress} -> {:ok, progress}
      :none -> read(path, serial)
    end
  end

  # contract: test/alavi/copy/progress_test.exs "load/2"
  @doc "Replaces the meter's progress with `progress`, synced before it returns."
  @spec save(Path.t(), String.t(), t()) :: :ok | {:error, {:file, File.posix()}}
  def save(dir, serial, progress) do
    path = path(dir, serial)

    with :ok <- file(File.mkdir_p(dir)),
         {:ok, fd} <- file(:file.open(path <> @new, [:write, :binary, :raw])),
         :ok <- written(fd, path <> @new, encode(serial, progress)) do
      file(:file.rename(path <> @new, path))
    end
  end

  # contract: test/alavi/copy/progress_test.exs "load/2"
  @spec encode(String.t(), t()) :: String.t()
  def encode(serial, progress) do
    stores =
      Map.new(progress, fn {store, at} ->
        {Atom.to_string(store), NaiveDateTime.to_iso8601(at)}
      end)

    JSON.encode!(%{"format" => @format, "meter_serial" => serial, "stores" => stores})
  end

  # contract: test/alavi/copy/progress_test.exs "load/2"
  @spec parse(binary(), String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(text, serial) do
    case JSON.decode(text) do
      {:ok, %{"format" => @format, "meter_serial" => ^serial, "stores" => %{} = stores} = json}
      when map_size(json) == 3 ->
        stores(stores)

      {:ok, %{"format" => @format, "meter_serial" => other}} ->
        {:error, "names meter #{inspect(other)}, not #{inspect(serial)}"}

      {:ok, _} ->
        {:error, "not an #{@format} record"}

      {:error, _} ->
        {:error, "not JSON"}
    end
  end

  defp stores(stores) do
    Enum.reduce_while(stores, {:ok, %{}}, fn {name, at}, {:ok, acc} ->
      with {:ok, store} <- Map.fetch(@stores, name),
           true <- is_binary(at),
           {:ok, %NaiveDateTime{} = stamp} <- NaiveDateTime.from_iso8601(at) do
        {:cont, {:ok, Map.put(acc, store, stamp)}}
      else
        _ -> {:halt, {:error, "store #{inspect(name)}: not a store with a meter time"}}
      end
    end)
  end

  defp read_new(path, serial) do
    with {:ok, text} <- File.read(path),
         {:ok, progress} <- parse(text, serial) do
      {:ok, progress}
    else
      {:error, :enoent} ->
        :none

      {:error, why} ->
        Logger.warning("alavi copies: #{path} does not read whole (#{inspect(why)}); passed over")
        :none
    end
  end

  defp read(path, serial) do
    case File.read(path) do
      {:ok, text} ->
        parsed(parse(text, serial), path)

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, {:unreadable, path, reason |> :file.format_error() |> to_string()}}
    end
  end

  defp parsed({:ok, progress}, _path), do: {:ok, progress}
  defp parsed({:error, why}, path), do: {:error, {:unreadable, path, why}}

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

  defp file(:ok), do: :ok
  defp file({:ok, fd}), do: {:ok, fd}
  defp file({:error, reason}), do: {:error, {:file, reason}}

  # Characters a file name may not hold become `_`; the record names its
  # serial, so two serials that map to one name cannot be confused.
  defp path(dir, serial),
    do: Path.join(dir, String.replace(serial, ~r/[^A-Za-z0-9.-]/, "_") <> @suffix)
end
