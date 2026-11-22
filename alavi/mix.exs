defmodule Alavi.MixProject do
  use Mix.Project

  def project do
    [
      app: :alavi,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      releases: [alavi: [steps: [:assemble, &service_options/1]]],
      dialyzer: [plt_add_apps: [:mix, :ex_unit]]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :inets, :ssl, :public_key],
      mod: {Alavi.Application, []}
    ]
  end

  def cli do
    [preferred_envs: [check: :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:decimal, "~> 3.2"},
      {:simulator, path: "../simulator", only: :test},
      {:jsv, "~> 0.27", only: :test},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  # Mix's bin\alavi.bat installs the Windows service with erlsrv's defaults,
  # and has no option for any of them:
  # - -onfail ignore, so a node that stops stays down. `restart`, not
  #   `restart_always`: a node that stops again within 10 s of a restart (a bad
  #   settings file stops it in under a second) is left stopped, not restarted
  #   in a loop.
  # - no working directory, so the node runs in the system directory and an
  #   erl_crash.dump, which can hold the token, lands there. In the release
  #   root it lands beside settings.json, under the ACL the README sets.
  # - a generated internal (SCM) name, under which a start at boot cannot find
  #   erlsrv's registry keys, which are under the service name: the service
  #   then does not start at boot. The internal name is set only on add.
  # - no stop action, so stopping the service kills the node: no copy stops at
  #   an entry boundary and no session closes. `init:stop()` stops the
  #   application, and its prep_stop stops the pollers first.
  defp service_options(release) do
    bat = Path.join([release.path, "bin", "#{release.name}.bat"])
    add = ~s|"!ERLSRV!" add "!RELEASE_NAME!_!RELEASE_NAME!" ^\n|

    options = """
      -onfail restart ^
      -workdir "!RELEASE_ROOT!" ^
      -internalservicename "!RELEASE_NAME!_!RELEASE_NAME!" ^
      -stopaction "init:stop()." ^
    """

    case String.split(File.read!(bat), add) do
      [head, tail] ->
        File.write!(bat, head <> add <> options <> tail)
        release

      _ ->
        Mix.raise(
          "#{bat}: no single erlsrv add line to put the service options on; has Mix's template changed?"
        )
    end
  end

  defp aliases do
    [
      check: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "dialyzer",
        "test"
      ]
    ]
  end
end
