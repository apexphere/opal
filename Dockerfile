# syntax=docker/dockerfile:1
# Build stage: compile the Opal escript with Elixir/OTP toolchain.
FROM elixir:1.19-otp-28 AS build

WORKDIR /app

# Cache hex/rebar across builds.
RUN mix local.hex --force && mix local.rebar --force

COPY elixir/mix.exs elixir/mix.lock ./
RUN mix deps.get --only prod

COPY elixir/ ./
RUN MIX_ENV=prod mix build

# Runtime stage: matches the build stage's OTP version so escript bytecode
# loads correctly. Adds git, ssh, and the Claude Code CLI on top.
FROM elixir:1.19-otp-28-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      nodejs \
      npm \
      openssh-client \
 && rm -rf /var/lib/apt/lists/* \
 && npm install -g @anthropic-ai/claude-code @openai/codex \
 && npm cache clean --force

COPY --from=build /app/bin/symphony /usr/local/bin/opal
COPY docker/default-WORKFLOW.md /etc/opal/default-WORKFLOW.md
COPY docker/entrypoint.sh /usr/local/bin/opal-entrypoint
RUN chmod +x /usr/local/bin/opal /usr/local/bin/opal-entrypoint

VOLUME /project
VOLUME /workspace

ENV WORKSPACE_ROOT=/workspace

# Phoenix LiveView observability dashboard. The default WORKFLOW.md binds
# this to 0.0.0.0:4000 inside the container; publish it with
# `docker run -p 4000:4000 ...` to view from the host.
EXPOSE 4000

ENTRYPOINT ["/usr/local/bin/opal-entrypoint"]
