defmodule Alavi.Config.SavedTest do
  use ExUnit.Case, async: true

  alias Alavi.Config.Saved

  @moduletag :tmp_dir
  @moduletag :capture_log

  @old %{"schema_version" => 1, "endpoints" => [%{"host" => "old"}]}
  @new %{"schema_version" => 1, "endpoints" => [%{"host" => "new", "é" => "\n"}]}

  defp path(dir), do: Saved.path(dir)

  describe "read/1" do
    test "nothing saved, in a directory that may not exist yet", %{tmp_dir: dir} do
      assert Saved.read(Path.join(dir, "absent")) == :none
      assert Saved.read(dir) == :none
    end

    test "a whole .new file is the newer; a torn one was never renamed and is passed over",
         %{tmp_dir: dir} do
      :ok = Saved.save(dir, @old)
      new = path(dir) <> ".new"

      File.write!(new, JSON.encode!(@new))
      assert Saved.read(dir) == {:ok, new, @new}

      File.write!(new, ~s({"schema_version": 1, "endp))
      assert Saved.read(dir) == {:ok, path(dir), @old}
    end

    test "a whole .new file with no saved file beside it: the rename deleted the old first",
         %{tmp_dir: dir} do
      :ok = Saved.save(dir, @old)
      File.rename!(path(dir), path(dir) <> ".new")
      assert {:ok, _new, @old} = Saved.read(dir)
    end

    test "a saved file that is not JSON is an error naming it", %{tmp_dir: dir} do
      :ok = Saved.save(dir, @old)
      File.write!(path(dir), "{")
      assert {:error, reason} = Saved.read(dir)
      assert reason =~ "#{path(dir)}: invalid JSON"
    end
  end

  describe "save/2" do
    test "what is saved is read back, and a later save replaces it, leaving no .new file",
         %{tmp_dir: dir} do
      assert :ok = Saved.save(dir, @old)
      assert Saved.read(dir) == {:ok, path(dir), @old}
      assert :ok = Saved.save(dir, @new)
      assert Saved.read(dir) == {:ok, path(dir), @new}
      refute File.exists?(path(dir) <> ".new")
    end

    test "a save that cannot write its new file leaves the saved config as it was",
         %{tmp_dir: dir} do
      :ok = Saved.save(dir, @old)
      before = File.read!(path(dir))
      File.mkdir_p!(path(dir) <> ".new")

      assert {:error, reason} = Saved.save(dir, @new)
      assert reason =~ path(dir) <> ".new"
      assert File.read!(path(dir)) == before
    end

    test "a save where the directory cannot be made is an error naming it", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "config"), "a file, not a directory")
      assert {:error, reason} = Saved.save(dir, @new)
      assert reason =~ path(dir)
    end
  end
end
