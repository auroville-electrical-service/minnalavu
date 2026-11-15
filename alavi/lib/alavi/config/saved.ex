defmodule Alavi.Config.Saved do
  @moduledoc """
  The polling config last served, kept under the collector's durable state (the
  buffer's `dir`) as `config/served.json`, so that it is what the collector
  starts from.

  It is replaced by writing `served.json.new` whole and synced, then renaming
  it over. A rename over an existing file need not be atomic (on Windows OTP
  may delete the old file first), so while a `.new` file exists that decodes
  whole, it is the newer, and one that does not was never renamed and is
  passed over. The directory itself is not synced: OTP cannot open a
  directory to sync it.
  """

  require Logger

  @name "served.json"
  @new ".new"

  # contract: test/alavi/config/saved_test.exs "read/1"
  @doc "The document as decoded, and the file it came from; not parsed against any profile."
  @spec read(Path.t()) :: {:ok, Path.t(), term()} | :none | {:error, String.t()}
  def read(dir) do
    path = path(dir)

    case read_new(path <> @new) do
      {:ok, document} -> {:ok, path <> @new, document}
      :none -> read_saved(path)
    end
  end

  # contract: test/alavi/config/saved_test.exs "save/2"
  @spec save(Path.t(), term()) :: :ok | {:error, String.t()}
  def save(dir, document) do
    path = path(dir)
    new = path <> @new

    with :ok <- file(File.mkdir_p(Path.dirname(path)), path),
         {:ok, fd} <- file(:file.open(new, [:write, :binary, :raw]), new),
         :ok <- written(fd, new, JSON.encode_to_iodata!(document)) do
      file(:file.rename(new, path), path)
    end
  end

  @doc "Where the config is saved under `dir`."
  @spec path(Path.t()) :: Path.t()
  def path(dir), do: Path.join([dir, "config", @name])

  defp read_new(path) do
    with {:ok, text} <- File.read(path),
         {:ok, document} <- JSON.decode(text) do
      {:ok, document}
    else
      {:error, :enoent} ->
        :none

      {:error, why} ->
        Logger.warning("alavi config: #{path} does not read whole (#{inspect(why)}); passed over")
        :none
    end
  end

  defp read_saved(path) do
    case File.read(path) do
      {:ok, text} -> decode(text, path)
      {:error, :enoent} -> :none
      {:error, reason} -> file({:error, reason}, path)
    end
  end

  defp decode(text, path) do
    case JSON.decode(text) do
      {:ok, document} -> {:ok, path, document}
      {:error, why} -> {:error, "#{path}: invalid JSON (#{inspect(why)})"}
    end
  end

  # A file not written whole is removed; if that fails too, it is passed over on reading.
  defp written(fd, path, data) do
    with :ok <- :file.write(fd, data),
         :ok <- :file.sync(fd) do
      file(:file.close(fd), path)
    else
      {:error, reason} ->
        _ = :file.close(fd)
        _ = File.rm(path)
        file({:error, reason}, path)
    end
  end

  defp file(:ok, _path), do: :ok
  defp file({:ok, value}, _path), do: {:ok, value}
  defp file({:error, reason}, path), do: {:error, "#{path}: #{:file.format_error(reason)}"}
end
