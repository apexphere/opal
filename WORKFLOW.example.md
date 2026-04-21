---
# Sample WORKFLOW.md for projects that want to customize Opal's default flow.
# Drop this at your project root as `WORKFLOW.md`, fill in `repo`, and
# run Opal via Docker (see docker/README.md).

tracker:
  kind: github                  # default; "linear" and "memory" are compatibility/test adapters
  repo: $GITHUB_REPO            # owner/repo — env var or hardcoded
  api_key: $GITHUB_TOKEN        # GitHub PAT or App token
  active_states: ["Todo", "In Progress"]
  terminal_states: ["Done", "Closed"]
  # labels_prefix: "opal:"      # optional — namespaces labels like opal:todo

agent:
  runtime: claude-code          # default; "codex" is a compatibility runtime
  max_concurrent_agents: 1      # how many issues to work in parallel
  max_turns: 20                 # max agent turns per issue

workspace:
  root: /workspace              # where per-issue checkouts live

polling:
  interval_ms: 30000

claude_code:
  command: claude
  permission_mode: acceptEdits
  allowed_tools: "Edit,Write,Read,Bash,Glob,Grep"

# Optional lifecycle hooks (shell commands).
# hooks:
#   after_create: "git clone $REPO_URL ."
#   before_run: "make setup"
#   after_run: "make test"

# Optional self-verification gate. This is the product direction, but projects
# can opt in before it becomes mandatory in the Docker default.
# verification:
#   enabled: true
#   required: true
#
# Optional: add a project-specific prompt body after the second `---`.
# Leave the body empty to use Opal's built-in generic project-adaptive prompt.
#
# Available template variables:
#   {{ task.number }}       — issue identifier (e.g. "#42" or "MT-123")
#   {{ task.title }}
#   {{ task.description }}
#   {{ task.state }}
#   {{ task.labels }}        — list
#   {{ task.url }}
#   {{ attempt }}            — retry attempt number (only on retries)
#
# (Legacy `{{ issue.X }}` aliases also work.)
---
