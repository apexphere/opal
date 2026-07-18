---
tracker:
  kind: github
  repo: apexphere/opal
  api_key: $GITHUB_TOKEN
  assignee: null
  active_states:
    - Todo
    - In Progress
  terminal_states:
    - Done
    - Closed
  labels_prefix: null
polling:
  interval_ms: 15000
workspace:
  root: ~/code/opal-dogfood-workspaces
hooks:
  after_create: |
    git clone --depth 1 https://github.com/apexphere/opal .
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise trust && mise exec -- mix deps.get
    fi
  timeout_ms: 300000
agent:
  runtime: claude-code
  max_concurrent_agents: 1
  max_turns: 10
claude_code:
  command: claude
  model: claude-sonnet-4-6
  allowed_tools: Edit,Write,Bash,Read,Glob,Grep
  permission_mode: acceptEdits
  extra_flags: []
  turn_timeout_ms: 3600000
verification:
  enabled: true
  required: false
  step_timeout_ms: 120000
  critic_enabled: true
  critic_timeout_ms: 180000
  critic_max_rejections: 2
server:
  port: 4100
observability:
  enabled: true
  refresh_ms: 1000
  render_interval_ms: 16
---

You are working on GitHub issue #{{ task.number }} in `apexphere/opal`.

Title: {{ task.title }}
URL: {{ task.url }}
Current state: {{ task.state }}
Labels: {{ task.labels }}

Description:
{% if task.description %}
{{ task.description }}
{% else %}
No description provided.
{% endif %}

## Operating rules

- This is an unattended run. Never ask a human to perform follow-up actions.
- Work in the provided repository copy only; do not touch other paths.
- Move the issue state by swapping labels (remove the current state label, add
  the new one). On completion, close the issue.
- On `Todo` kickoff: remove `todo`, add `in-progress`, then do the work.
- When the work is ready for human review: open a PR linked to the issue,
  remove `in-progress`, add `human-review`.
- Final message: report completed actions and blockers only. No "next steps for
  user" section.

## Verification (mandatory)

This run is part of Opal's self-verifying dogfood. Before you claim done, write
a `.opal/verify.json` that exercises the change the way a user would — boot the
thing, hit it, check the response. Opal will run every step and revert the
issue to active if any step fails. Unit tests are not a substitute; the recipe
must prove the user-visible behaviour you delivered actually works.
