defmodule Alavi.ConfigKeeperTest do
  use ExUnit.Case, async: true

  import Alavi.PollerCase

  alias Alavi.{Config, ConfigKeeper}
  alias Alavi.Config.{Digest, Saved}

  @moduletag :tmp_dir
  @moduletag :capture_log

  defp document(port, meters \\ [meter(1, "elite_440")]),
    do: %{"schema_version" => 1, "endpoints" => [endpoint(port, "tcp", meters)]}

  defp digest!(document) do
    {:ok, digest} = Digest.digest(document)
    digest
  end

  # The server serves whatever `served` holds now; each fetch, and each config
  # applied and report cast to the status, is sent to the test.
  defp keeper!(dir, served) do
    test = self()
    start = document(5020)
    {:ok, config} = Config.parse(start, profiles())

    fetch = fn ->
      send(test, :fetched)
      Agent.get(served, & &1)
    end

    opts = [
      config: config,
      digest: digest!(start),
      profiles: profiles(),
      dir: dir,
      fetch: fetch,
      applied: fn config, digest -> send(test, {:applied, config, digest}) end,
      status: test
    ]

    {start_supervised!({ConfigKeeper, opts}), digest!(start)}
  end

  defp served!(result), do: start_supervised!({Agent, fn -> result end})
  defp serve(served, result), do: Agent.update(served, fn _ -> result end)

  # A cast is handled before the call that follows it.
  defp answer(keeper, digest) do
    :ok = ConfigKeeper.answered(keeper, digest)
    ConfigKeeper.report(keeper)
  end

  describe "answered/2" do
    test "the digest of the config applied: nothing is fetched", %{tmp_dir: dir} do
      {keeper, digest} = keeper!(dir, served!({:error, "unused"}))
      assert_receive {:"$gen_cast", {:config, %{digest: ^digest, refused: nil}}}

      assert answer(keeper, digest) == %{digest: digest, refused: nil}
      refute_received :fetched
    end

    test "another digest: the served config is fetched, saved, applied and reported",
         %{tmp_dir: dir} do
      new = document(5021)
      {keeper, _digest} = keeper!(dir, served!({:ok, new}))
      digest = digest!(new)

      assert answer(keeper, digest) == %{digest: digest, refused: nil}
      assert_received :fetched
      assert_received {:applied, %Config{endpoints: [%{port: 5021}]}, ^digest}
      assert_received {:"$gen_cast", {:config, %{digest: ^digest}}}
      assert {%Config{endpoints: [%{port: 5021}]}, ^digest} = ConfigKeeper.current(keeper)
      assert {:ok, _path, ^new} = Saved.read(dir)

      answer(keeper, digest)
      refute_received :fetched
    end

    test "a config that does not parse is refused, kept from, and not fetched again",
         %{tmp_dir: dir} do
      bad = document(5021, [meter(1, "no_such_profile")])
      {keeper, digest} = keeper!(dir, served!({:ok, bad}))
      refused = digest!(bad)

      assert %{digest: ^digest, refused: %{digest: ^refused, reason: reason}} =
               answer(keeper, refused)

      assert reason =~ "no_such_profile"
      assert_received :fetched
      refute_received {:applied, _, _}
      assert {_config, ^digest} = ConfigKeeper.current(keeper)
      assert Saved.read(dir) == :none

      assert %{refused: %{digest: ^refused}} = answer(keeper, refused)
      refute_received :fetched
    end

    test "a refusal is cleared by a config applied in its place, or by the server serving the one applied again",
         %{tmp_dir: dir} do
      bad = document(5021, [meter(1, "no_such_profile")])
      served = served!({:ok, bad})
      {keeper, digest} = keeper!(dir, served)

      assert %{refused: %{}} = answer(keeper, digest!(bad))
      assert answer(keeper, digest) == %{digest: digest, refused: nil}

      assert %{refused: %{}} = answer(keeper, digest!(bad))
      good = document(5022)
      serve(served, {:ok, good})
      assert answer(keeper, digest!(good)) == %{digest: digest!(good), refused: nil}
    end

    test "the config fetched is judged by its own digest, not the answer's", %{tmp_dir: dir} do
      new = document(5021)
      {keeper, _digest} = keeper!(dir, served!({:ok, new}))
      stale = String.duplicate("0", 64)

      assert answer(keeper, stale) == %{digest: digest!(new), refused: nil}
    end

    test "a fetch that fails is no refusal: the next answer fetches again", %{tmp_dir: dir} do
      served = served!({:error, "HTTP 503: down"})
      {keeper, digest} = keeper!(dir, served)
      new = document(5021)

      assert answer(keeper, digest!(new)) == %{digest: digest, refused: nil}
      assert_received :fetched
      serve(served, {:ok, new})
      assert answer(keeper, digest!(new)) == %{digest: digest!(new), refused: nil}
      assert_received :fetched
    end

    test "a document with no canonical form is no refusal either", %{tmp_dir: dir} do
      served = served!({:ok, %{"schema_version" => 1.5}})
      {keeper, digest} = keeper!(dir, served)
      stale = String.duplicate("0", 64)

      assert answer(keeper, stale) == %{digest: digest, refused: nil}
      assert answer(keeper, stale) == %{digest: digest, refused: nil}
      assert_received :fetched
      assert_received :fetched
    end

    test "a config that cannot be saved is not applied, and fetched again on the next answer",
         %{tmp_dir: dir} do
      File.write!(Path.join(dir, "config"), "a file, not a directory")
      new = document(5021)
      {keeper, digest} = keeper!(dir, served!({:ok, new}))

      assert answer(keeper, digest!(new)) == %{digest: digest, refused: nil}
      assert answer(keeper, digest!(new)) == %{digest: digest, refused: nil}
      assert_received :fetched
      assert_received :fetched
      refute_received {:applied, _, _}
    end
  end
end
