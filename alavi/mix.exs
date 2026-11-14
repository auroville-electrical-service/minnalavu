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
      releases: [alavi: [steps: [:assemble, &restart_on_failure/1]]],
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

  # Mix's bin\alavi.bat installs the Windows service with erlsrv's default,
  # -onfail ignore, so a node that stops stays down, and it has no option for
  # it. `restart`, not `restart_always`: a node that stops again within 10 s of
  # a restart (a bad settings file stops it in under a second) is left stopped,
  # not restarted in a loop.
  defp restart_on_failure(release) do
    bat = Path.join([release.path, "bin", "#{release.name}.bat"])
    add = ~s|"!ERLSRV!" add "!RELEASE_NAME!_!RELEASE_NAME!" ^\n|

    case String.split(File.read!(bat), add) do
      [head, tail] ->
        File.write!(bat, head <> add <> "  -onfail restart ^\n" <> tail)
        release

      _ ->
        Mix.raise(
          "#{bat}: no single erlsrv add line to put -onfail on; has Mix's template changed?"
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
