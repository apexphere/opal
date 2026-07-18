---
tracker:
  kind: github
  repo: $GITHUB_REPO
  api_key: $GITHUB_TOKEN
  active_states: ["Todo", "In Progress"]
  terminal_states: ["Done", "Closed"]
agent:
  runtime: claude-code
  max_concurrent_agents: 1
  max_turns: 20
workspace:
  root: /workspace
polling:
  interval_ms: 30000
claude_code:
  command: claude
  permission_mode: acceptEdits
  allowed_tools: "Edit,Write,Read,Bash,Glob,Grep"
  # Kill the subprocess if no stream-json output arrives for this long
  # (default 5 min). Catches a wedged claude faster than the 1h hard timeout.
  stall_timeout_ms: 300000
server:
  # Bind to 0.0.0.0 so the dashboard is reachable from outside the container
  # when started with `docker run -p 4000:4000 ...`.
  host: "0.0.0.0"
  port: 4000
---

(Empty body — Opal will use its built-in generic project-adaptive prompt.)
