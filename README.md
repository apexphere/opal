# Opal — Orchestrated Project Agent Layer

Opal is a containerized agent orchestrator that can work on any project. Mount a project volume,
point Opal at it, and autonomous coding agents pick up issues from GitHub and deliver PRs — guided
by the project's own documentation.

Built on [OpenAI's Symphony](https://github.com/openai/symphony) orchestration framework (Elixir/OTP),
extended with:

- **GitHub Issues** as the task source (replacing Linear)
- **Claude Code** (`claude -p`) as the agent runtime (replacing Codex)
- **Project-adaptive prompts** that read your project's own CLAUDE.md / README and follow them
- **Per-project knowledge** — Opal accumulates experience knowledge per target project and injects
  it into each agent run, without polluting the target repo
- **Docker packaging** for drop-in use with any codebase

> [!WARNING]
> Opal is under active development. The three adapter issues are tracked in GitHub Issues.

## Vision

```bash
docker run -v /path/to/your-project:/project \
           -v /tmp/workspaces:/workspace \
           -e GITHUB_TOKEN=ghp_... \
           opal:latest
```

Opal reads the project's documentation, polls GitHub Issues for work, creates isolated workspaces,
and runs Claude Code agents to implement, test, and open PRs — all without project-specific
configuration.

## Roadmap

| # | Feature | Status |
|---|---------|--------|
| [#1](https://github.com/apexphere/opal/issues/1) | GitHub Issues tracker adapter | Planned |
| [#2](https://github.com/apexphere/opal/issues/2) | Claude Code agent adapter (`claude -p`) | Planned |
| [#3](https://github.com/apexphere/opal/issues/3) | Generic prompt + Docker packaging | Planned |

## Current state

The codebase is forked from [openai/symphony](https://github.com/openai/symphony) and includes:

- **Orchestrator** — GenServer polling loop with concurrency, retries, and reconciliation
- **Workspace manager** — per-issue isolation with lifecycle hooks
- **Knowledge subsystem** — per-project experience knowledge, filesystem-backed by default,
  dynamically injected into each agent run (see SPEC §9.6)
- **Prompt builder** — Liquid template rendering with task context
- **Observability** — terminal dashboard + Phoenix LiveView UI
- **SPEC.md** — language-agnostic specification for building your own

See [elixir/README.md](elixir/README.md) for the Elixir reference implementation setup.

## License

This project is licensed under the [Apache License 2.0](LICENSE).
