# The end-to-end tests need the central store running; see CLAUDE.md
# (bin/dev alavi mix test --only e2e).
ExUnit.start(exclude: [:e2e])
