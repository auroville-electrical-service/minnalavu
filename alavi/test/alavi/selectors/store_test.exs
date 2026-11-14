defmodule Alavi.Selectors.StoreTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Alavi.Selectors.{Record, Store}

  @moduletag :tmp_dir
  @endpoint %{host: "127.0.0.1", port: 5020}

  defp record(value \\ 0) do
    %Record{
      endpoint: @endpoint,
      unit_id: 1,
      model: "elite_440",
      selectors: [%{name: :history, value: value, bound: 6}]
    }
  end

  defp file(dir, suffix), do: Path.join(dir, "127.0.0.1_5020" <> suffix)

  describe "owed/2" do
    test "nothing owed in an empty or missing directory", %{tmp_dir: dir} do
      assert Store.owed(dir, @endpoint) == :none
      assert Store.owed(Path.join(dir, "absent"), @endpoint) == :none
    end

    test "a torn record, or one naming another endpoint, is unreadable, never nothing",
         %{tmp_dir: dir} do
      text = Record.encode(record())
      File.write!(file(dir, ".restore"), binary_part(text, 0, 20))
      assert {:error, {:unreadable, path, _why}} = Store.owed(dir, @endpoint)
      assert path == file(dir, ".restore")

      File.write!(file(dir, ".restore"), "")
      assert {:error, {:unreadable, _, _}} = Store.owed(dir, @endpoint)

      other = %{record() | endpoint: %{@endpoint | host: "127.0.0.1x"}}
      File.write!(file(dir, ".restore"), Record.encode(other))
      assert {:error, {:unreadable, _, "names endpoint" <> _}} = Store.owed(dir, @endpoint)
    end
  end

  describe "owe/2" do
    test "saves the record whole, never replaces one, and clear/2 deletes it", %{tmp_dir: dir} do
      sub = Path.join(dir, "selectors")
      assert Store.owe(sub, record()) == :ok
      assert Store.owed(sub, @endpoint) == {:ok, record()}

      assert Store.owe(sub, record(3)) == {:error, :owed}
      assert Store.owed(sub, @endpoint) == {:ok, record()}

      assert Store.clear(sub, @endpoint) == :ok
      assert Store.owed(sub, @endpoint) == :none
    end

    test "an unreadable record is not replaced either", %{tmp_dir: dir} do
      File.write!(file(dir, ".restore"), "{")
      assert Store.owe(dir, record()) == {:error, :owed}
      assert File.read!(file(dir, ".restore")) == "{"
    end

    test "a host's characters a file name cannot hold do not reach the name", %{tmp_dir: dir} do
      endpoint = %{host: "fe80::1", port: 502}
      assert Store.owe(dir, %{record() | endpoint: endpoint}) == :ok
      assert File.ls!(dir) == ["fe80__1_502.restore"]
      assert {:ok, %Record{endpoint: ^endpoint}} = Store.owed(dir, endpoint)
    end
  end

  describe "left/2" do
    test "nothing left at first; leave/3 merges", %{tmp_dir: dir} do
      assert Store.left(dir, @endpoint) == {:ok, %{}}
      assert Store.leave(dir, @endpoint, %{{1, "elite_440", :history} => 0}) == :ok
      assert Store.leave(dir, @endpoint, %{{2, "elite_440", :snapshot} => 4}) == :ok

      assert Store.left(dir, @endpoint) ==
               {:ok, %{{1, "elite_440", :history} => 0, {2, "elite_440", :snapshot} => 4}}

      assert File.ls!(dir) == ["127.0.0.1_5020.left"]
    end

    test "a whole .new file is the newer; a torn one was never renamed and is passed over",
         %{tmp_dir: dir} do
      :ok = Store.leave(dir, @endpoint, %{{1, "elite_440", :history} => 0})
      newer = Record.encode_left(@endpoint, %{{1, "elite_440", :history} => 5})

      File.write!(file(dir, ".left.new"), newer)
      assert Store.left(dir, @endpoint) == {:ok, %{{1, "elite_440", :history} => 5}}

      File.rm!(file(dir, ".left"))
      assert Store.left(dir, @endpoint) == {:ok, %{{1, "elite_440", :history} => 5}}

      :ok = Store.leave(dir, @endpoint, %{{1, "elite_440", :history} => 0})
      File.write!(file(dir, ".left.new"), binary_part(newer, 0, 10))

      log =
        capture_log(fn ->
          assert {:ok, %{{1, "elite_440", :history} => 0}} = Store.left(dir, @endpoint)
        end)

      assert log =~ "does not read whole"
    end

    test "an unreadable left record is an error, and leave/3 does not replace it",
         %{tmp_dir: dir} do
      File.write!(file(dir, ".left"), "[]")
      assert {:error, {:unreadable, _, _}} = Store.left(dir, @endpoint)

      assert {:error, {:unreadable, _, _}} =
               Store.leave(dir, @endpoint, %{{1, "elite_440", :history} => 0})

      assert File.read!(file(dir, ".left")) == "[]"
    end
  end
end
