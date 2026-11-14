import Config

# Dev and test start no collector; tests start what they need. A release
# gets its settings from config/runtime.exs.
if config_env() in [:dev, :test] do
  config :alavi, collector: :disabled
end

# A release logs with the date, in UTC, as a collector's log is read days later
# and beside the server's. Crash reports and supervisor reports are logged
# (handle_sasl_reports), and the level is :debug because only then does a
# GenServer's crash report include its state. The collector logs nothing at
# debug itself; OTP adds a line or two at boot. The log is a file, so no
# colour codes: left on, they are written into it as escape sequences.
if config_env() == :prod do
  config :logger,
    level: :debug,
    handle_sasl_reports: true

  config :logger, :default_formatter,
    format: "$date $time [$level] $message\n",
    colors: [enabled: false],
    utc_log: true
end
