import Config

# A release reads its settings from one file, settings.json in the release
# root, and nowhere else; an unreadable or invalid file stops startup with the
# reason. The keys and their meanings are in Alavi.Settings. Logs go to a
# rotating file named there, from here on, so the collector's own start and
# any crash land in it; a settings error comes before it and goes to stdout.
if config_env() == :prod do
  path = Path.join(System.fetch_env!("RELEASE_ROOT"), "settings.json")

  case Alavi.Settings.load(path) do
    {:ok, settings} ->
      config :alavi, collector: settings
      config :logger, :default_handler, config: Alavi.Settings.log_file(settings)

    {:error, message} ->
      raise "alavi cannot start: #{message}"
  end
end
