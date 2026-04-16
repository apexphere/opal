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
---

(Empty body — Opal will use its built-in generic project-adaptive prompt.)
