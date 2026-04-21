# Opal Docker image

Run Opal as a containerized agent orchestrator: mount any project, point it at
GitHub Issues, and let Claude Code work the queue.

## Build

```bash
docker build -t opal .
```

## Run

The image expects two volumes and two environment variables:

| Path / var      | Purpose                                        |
| --------------- | ---------------------------------------------- |
| `/project`      | Bind-mount of the project Opal clones per issue |
| `/workspace`    | Bind-mount where per-issue workspaces are kept |
| `GITHUB_TOKEN`  | GitHub PAT or GitHub App token                 |
| `GITHUB_REPO`   | `owner/repo` (only used by the default config) |

Before starting, make sure the target repo has labels for Opal's default issue states:

- `todo`
- `in-progress`
- `human-review`

Open issues with the `todo` label are eligible for pickup. Opal swaps the state label as work
progresses; closing the issue represents `Done` / `Closed`.

Minimal invocation:

```bash
docker run --rm -it \
  -p 4000:4000 \
  -v "$PWD":/project \
  -v /tmp/opal-workspaces:/workspace \
  -e GITHUB_TOKEN=ghp_... \
  -e GITHUB_REPO=owner/repo \
  opal
```

## Observability dashboard

The Phoenix LiveView dashboard listens on port `4000` inside the container
(bound to `0.0.0.0` by the default WORKFLOW.md). Publish the port with
`-p 4000:4000` and open <http://localhost:4000> to watch live agent activity,
token usage, rate limits, and the running/queued agent table.

To pick a different host port, change the left side of `-p`, e.g.
`-p 8080:4000` then visit <http://localhost:8080>.

To disable the dashboard entirely, set `observability.dashboard_enabled:
false` and/or remove the `server:` block in your project's `WORKFLOW.md`.

## How the WORKFLOW.md is selected

The entrypoint picks the first match it finds:

1. `/project/WORKFLOW.md` — your project's own config and prompt override
2. `/etc/opal/default-WORKFLOW.md` — the image's built-in default

The default WORKFLOW.md ships with `tracker.kind: github`, `agent.runtime:
claude-code`, an `after_create` hook that runs `git clone /project .` inside
each new issue workspace, required self-verification, a recipe critic gate, and
an empty prompt body — which causes Opal to use its built-in generic
project-adaptive prompt. That prompt tells the agent to read your project's
`CLAUDE.md` / `AGENTS.md` / `README.md` / `CONTRIBUTING.md` and follow them as
authoritative.

Because the default recipe critic invokes `codex exec`, mount an authenticated
Codex config into the container, for example `-v "$HOME/.codex":/root/.codex:ro`.
If you do not want to provide Codex auth yet, set
`verification.critic_enabled: false` in your project `WORKFLOW.md`; verification
still runs, but recipe-quality criticism is skipped.

Docker uses a 10-minute `verification.step_timeout_ms` so real project
integration checks have room to boot services and exercise the delivered
surface. Lower it in `WORKFLOW.md` if a broken verification step should fail
faster for your project.

In other words: a project with no Opal-specific config gets sensible defaults.
A project that wants to customize anything just drops a `WORKFLOW.md` at its
root.

The default config is intentionally narrow: GitHub Issues + Claude Code +
Docker workspaces. Linear and Codex are still available in the Elixir
implementation for compatibility, but they are not the default Docker path.

## Project agent docs

Claude Code auto-discovers the following from `cwd=/project`:

- `CLAUDE.md` (system prompt)
- `AGENTS.md`
- `.claude/skills/`
- `.claude/agents/`

You don't need to do anything special — just have those files in your repo.

## Customizing the prompt or config

Drop a `WORKFLOW.md` at your project root with YAML front matter and an
optional Liquid template body. See the repo-root `WORKFLOW.example.md` for a
ready-to-copy starting point.

Common overrides:

- `tracker.labels_prefix` namespaces state labels, for example `opal:todo`.
- `agent.max_concurrent_agents` raises or lowers the number of issues Opal may work at once.
- `hooks.after_create` can replace the default `git clone /project .` bootstrap if a project needs
  a different checkout or setup flow.
- `verification.enabled`, `verification.required`, and `verification.critic_enabled` can be set to
  `false` for a project that needs to temporarily opt out of the default self-verification gate or
  recipe critic.
- `verification.step_timeout_ms` controls the per-step timeout for verification commands.

## Image contents

- Erlang/OTP 28 runtime
- Opal escript at `/usr/local/bin/opal`
- `git`, `openssh-client`, `nodejs`, `npm`
- `claude` CLI from `@anthropic-ai/claude-code`
- `codex` CLI from `@openai/codex` for verification recipe criticism
