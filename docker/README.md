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
| `/project`      | Bind-mount of the project Opal is working on   |
| `/workspace`    | Bind-mount where per-issue workspaces are kept |
| `GITHUB_TOKEN`  | GitHub PAT or GitHub App token                 |
| `GITHUB_REPO`   | `owner/repo` (only used by the default config) |

Minimal invocation:

```bash
docker run --rm -it \
  -v "$PWD":/project \
  -v /tmp/opal-workspaces:/workspace \
  -e GITHUB_TOKEN=ghp_... \
  -e GITHUB_REPO=owner/repo \
  opal
```

## How the WORKFLOW.md is selected

The entrypoint picks the first match it finds:

1. `/project/WORKFLOW.md` — your project's own config and prompt override
2. `/etc/opal/default-WORKFLOW.md` — the image's built-in default

The default WORKFLOW.md ships with `tracker.kind: github`, `agent.runtime:
claude-code`, and an empty prompt body — which causes Opal to use its built-in
generic project-adaptive prompt. That prompt tells the agent to read your
project's `CLAUDE.md` / `AGENTS.md` / `README.md` / `CONTRIBUTING.md` and
follow them as authoritative.

In other words: a project with no Opal-specific config gets sensible defaults.
A project that wants to customize anything just drops a `WORKFLOW.md` at its
root.

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

## Image contents

- Erlang/OTP 28 runtime
- Opal escript at `/usr/local/bin/opal`
- `git`, `openssh-client`, `nodejs`, `npm`
- `claude` CLI from `@anthropic-ai/claude-code`
