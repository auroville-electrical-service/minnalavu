defmodule Alavi.ConfigKeeper do
  @moduledoc """
  Holds the polling config the collector applies, by its digest
  (`Alavi.Config.Digest`), and the served config it last refused.

  Every server answer names the digest of the config the server serves
  (`answered/2`). One that is neither the config applied nor the one refused
  is fetched (`fetch`) and parsed against the loaded profiles as the local
  file is. One that parses is saved (`Alavi.Config.Saved`), so the collector
  starts from it, becomes the config applied, and is handed to `applied`;
  one that does not is refused, and not fetched again while the server
  serves it. A fetch that fails is no refusal: the next answer tries again.
  An answer naming the config applied clears a refusal, for the server no
  longer serves what was refused.

  What it holds is in each batch's backlog (`report/1`) and on the status.
  """

  use GenServer

  require Logger

  alias Alavi.{Config, Profile, Status}
  alias Alavi.Config.{Digest, Saved}

  @typedoc "`reason` is the parser's."
  @type refusal :: %{digest: Digest.t(), reason: String.t()}

  @type report :: %{digest: Digest.t(), refused: refusal() | nil}

  @typedoc """
  `config` and `digest` are what the collector started from. `dir` is the
  collector's durable state, the buffer's `dir`. `fetch` asks the server for
  the config it serves this collector; `applied` takes each config that
  becomes the one applied.
  """
  @type option ::
          {:config, Config.t()}
          | {:digest, Digest.t()}
          | {:profiles, %{String.t() => Profile.t()}}
          | {:dir, Path.t()}
          | {:fetch, (-> {:ok, term()} | {:error, String.t()})}
          | {:applied, (Config.t(), Digest.t() -> term())}
          | {:status, GenServer.server()}
          | {:name, GenServer.name()}

  # contract: test/alavi/config_keeper_test.exs "answered/2"
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  # contract: test/alavi/config_keeper_test.exs "answered/2"
  @doc "A server answer named `digest` as the config it serves."
  @spec answered(GenServer.server(), Digest.t()) :: :ok
  def answered(server, digest), do: GenServer.cast(server, {:answered, digest})

  # contract: test/alavi/config_keeper_test.exs "answered/2"
  @doc "Waits for a fetch under way, which its own timeout bounds."
  @spec report(GenServer.server()) :: report()
  def report(server), do: GenServer.call(server, :report, :infinity)

  # contract: test/alavi/config_keeper_test.exs "answered/2"
  @spec current(GenServer.server()) :: {Config.t(), Digest.t()}
  def current(server), do: GenServer.call(server, :current, :infinity)

  @impl true
  def init(opts) do
    state = %{
      config: Keyword.fetch!(opts, :config),
      digest: Keyword.fetch!(opts, :digest),
      refused: nil,
      profiles: Keyword.fetch!(opts, :profiles),
      dir: Keyword.fetch!(opts, :dir),
      fetch: Keyword.fetch!(opts, :fetch),
      applied: Keyword.fetch!(opts, :applied),
      status: Keyword.fetch!(opts, :status)
    }

    {:ok, reported(state)}
  end

  @impl true
  def handle_call(:report, _from, state), do: {:reply, report_of(state), state}
  def handle_call(:current, _from, state), do: {:reply, {state.config, state.digest}, state}

  @impl true
  def handle_cast({:answered, digest}, state), do: {:noreply, answered_with(state, digest)}

  defp answered_with(%{digest: digest} = state, digest), do: cleared(state)
  defp answered_with(%{refused: %{digest: digest}} = state, digest), do: state

  defp answered_with(state, digest) do
    with {:ok, document} <- state.fetch.(),
         {:ok, served} <- Digest.digest(document) do
      offered(state, served, document)
    else
      {:error, why} ->
        Logger.warning(
          "alavi config: the server serves config #{digest}, which could not be fetched " <>
            "(#{why}); trying again on a later answer"
        )

        state
    end
  end

  # The server's config may have changed again between its answer and the fetch.
  defp offered(%{digest: digest} = state, digest, _document), do: cleared(state)
  defp offered(%{refused: %{digest: digest}} = state, digest, _document), do: state

  defp offered(state, digest, document) do
    case Config.parse(document, state.profiles) do
      {:ok, config} -> save(state, config, digest, document)
      {:error, reason} -> refuse(state, digest, reason)
    end
  end

  defp save(state, config, digest, document) do
    case Saved.save(state.dir, document) do
      :ok ->
        Logger.info("alavi config: the served config #{digest} saved, replacing #{state.digest}")
        state.applied.(config, digest)
        reported(%{state | config: config, digest: digest, refused: nil})

      {:error, why} ->
        Logger.error(
          "alavi config: the served config #{digest} could not be saved (#{why}); " <>
            "still applying #{state.digest}, and trying again on a later answer"
        )

        state
    end
  end

  defp refuse(state, digest, reason) do
    Logger.error(
      "alavi config: the served config #{digest} is refused: #{reason}; " <>
        "still applying #{state.digest}"
    )

    reported(%{state | refused: %{digest: digest, reason: reason}})
  end

  defp cleared(%{refused: nil} = state), do: state

  defp cleared(state) do
    Logger.info(
      "alavi config: the server serves #{state.digest}, the config applied, again; " <>
        "the refusal of #{state.refused.digest} is cleared"
    )

    reported(%{state | refused: nil})
  end

  defp reported(state) do
    Status.config(state.status, report_of(state))
    state
  end

  defp report_of(state), do: %{digest: state.digest, refused: state.refused}
end
