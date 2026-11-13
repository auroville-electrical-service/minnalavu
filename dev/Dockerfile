# Development toolchain for every project in the repo.
# Pinned: bump the tags when a new stable Elixir/OTP, bun, dbmate, ShellCheck
# or shfmt ships.
FROM ghcr.io/amacneil/dbmate:2.37.0 AS dbmate
FROM koalaman/shellcheck:v0.11.0 AS shellcheck
FROM mvdan/shfmt:v3.12.0 AS shfmt
FROM oven/bun:1.3.14-debian AS bun

FROM hexpm/elixir:1.20.5-erlang-29.1.2-debian-trixie-20261104

# postgresql-client: psql, for central/'s migrations and SQL tests.
# curl: central/bin/alert sends mail with it.
RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git ca-certificates \
    postgresql-client curl \
  && rm -rf /var/lib/apt/lists/*

COPY --from=dbmate /usr/local/bin/dbmate /usr/local/bin/dbmate
COPY --from=shellcheck /bin/shellcheck /usr/local/bin/shellcheck
COPY --from=shfmt /bin/shfmt /usr/local/bin/shfmt
# bun: kai_alavi/, the handheld collector's TypeScript library.
COPY --from=bun /usr/local/bin/bun /usr/local/bin/bun
RUN ln -s bun /usr/local/bin/bunx

RUN mix local.hex --force && mix local.rebar --force

WORKDIR /work
