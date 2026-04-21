# Opal — Orchestrated Project Agent Layer

Opal is a containerized agent orchestrator for one developer and many projects. Mount a project
volume, point Opal at GitHub Issues, and Claude Code agents pick up issues, work in isolated
workspaces, and hand you pull requests — guided by the project's own documentation. The product
direction is to make every handoff pass through self-verification first.

Built on [OpenAI's Symphony](https://github.com/openai/symphony) orchestration framework
(Elixir/OTP), narrowed around Opal's golden path:

- **GitHub Issues** as the default task source
- **Claude Code** (`claude -p`) as the default agent runtime
- **Self-verification** through `.opal/verify.json` recipes before handoff
- **Project-adaptive prompts** that read your project's own CLAUDE.md / README and follow them
- **Per-project knowledge** — Opal accumulates experience knowledge per target project and injects
  it into each agent run, without polluting the target repo
- **Docker packaging** for drop-in use with any codebase

> [!WARNING]
> Opal is under active development. The supported happy path is Docker + GitHub Issues +
> Claude Code. Linear and Codex remain compatibility paths inherited from Symphony.

## Vision

See [VISION.md](VISION.md) — what Opal is, who it's for, and the three pillars
(self-verifying, self-learning, subscription-native) that guide development.

## Quickstart

Build the image:

```bash
docker build -t opal .
```

Prepare the target GitHub repo with issue labels matching Opal's default states:

- `todo`
- `in-progress`
- `human-review`

Then run Opal from the project checkout you want it to operate on:

```bash
docker run --rm -it \
  -p 4000:4000 \
  -v "$PWD":/project \
  -v /tmp/opal-workspaces:/workspace \
  -e GITHUB_TOKEN=ghp_... \
  -e GITHUB_REPO=owner/repo \
  opal
```

Opal reads the project's documentation, polls GitHub Issues for work, creates isolated workspaces,
and runs Claude Code agents to implement, test, and open PRs — all without project-specific
configuration.

Open <http://localhost:4000> to watch the live dashboard.

## Golden Path

The first path Opal is optimizing for is intentionally narrow:

1. Poll GitHub Issues with state labels.
2. Create one workspace per issue under `/workspace`.
3. Clone `/project` into the issue workspace.
4. Create a branch using the issue number.
5. Run Claude Code via `claude -p`.
6. Require the agent to emit `.opal/verify.json`.
7. Execute the verification recipe from the workspace.
8. Feed failures back into a follow-up turn, or hand off a PR when verification passes.
9. Distill useful run evidence into the per-project knowledge layer.

Other tracker/runtime adapters should preserve this flow rather than redefine it.

## Roadmap

Current focus:

| # | Feature | Status |
|---|---------|--------|
| [#46](https://github.com/apexphere/opal/issues/46) | Make Docker + GitHub + Claude Code the canonical golden path | Active |
| [#47](https://github.com/apexphere/opal/issues/47) | Add deterministic golden-path fake run test | Planned |
| [#48](https://github.com/apexphere/opal/issues/48) | Make self-verification a required gate in the default Opal flow | Planned |
| [#49](https://github.com/apexphere/opal/issues/49) | Capture useful wiki learning from completed or failed verification runs | Planned |
| [#50](https://github.com/apexphere/opal/issues/50) | Expose a concise operator narrative for where Opal is and what happens next | Planned |

## Current state

The codebase is forked from [openai/symphony](https://github.com/openai/symphony) and includes:

- **Orchestrator** — GenServer polling loop with concurrency, retries, and reconciliation
- **Workspace manager** — per-issue isolation with lifecycle hooks
- **Tracker adapters** — GitHub by default, plus Linear and memory adapters
- **Agent runtimes** — Claude Code by default, plus Codex app-server compatibility
- **Self-verification** — workspace-local recipes and verification logs
- **Knowledge subsystem** — per-project experience knowledge, filesystem-backed by default,
  dynamically injected into each agent run (see SPEC §9.6)
- **Prompt builder** — Liquid template rendering with task context
- **Observability** — terminal dashboard + Phoenix LiveView UI
- **SPEC.md** — language-agnostic specification for building your own

See [docker/README.md](docker/README.md) for the default runtime path and
[elixir/README.md](elixir/README.md) for implementation details.

## License

This project is licensed under the [Apache License 2.0](LICENSE).
