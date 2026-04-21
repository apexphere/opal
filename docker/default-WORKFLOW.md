---
tracker:
  kind: github
  repo: $GITHUB_REPO
  api_key: $GITHUB_TOKEN
  # GitHub labels backing the default state machine:
  #   Todo -> `todo`
  #   In Progress -> `in-progress`
  #   Human Review -> `human-review`
  # Closed issues are treated as Done / Closed.
  active_states: ["Todo", "In Progress"]
  terminal_states: ["Done", "Closed"]
agent:
  runtime: claude-code
  max_concurrent_agents: 1
  max_turns: 20
workspace:
  root: /workspace
hooks:
  after_create: |
    git clone /project .
polling:
  interval_ms: 30000
verification:
  enabled: true
  required: true
  step_timeout_ms: 600000
claude_code:
  command: claude
  permission_mode: acceptEdits
  allowed_tools: "Edit,Write,Read,Bash,Glob,Grep"
server:
  # Bind to 0.0.0.0 so the dashboard is reachable from outside the container
  # when started with `docker run -p 4000:4000 ...`.
  host: "0.0.0.0"
  port: 4000
---
