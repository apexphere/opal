#!/bin/sh
# Opal Docker entrypoint.
#
# Selects the WORKFLOW.md to run with:
#   1. If `/project/WORKFLOW.md` exists, use it (project provided one).
#   2. Otherwise fall back to the baked-in `/etc/opal/default-WORKFLOW.md`.
#
# Working directory is set to /project so Claude Code auto-discovers the
# project's own CLAUDE.md, AGENTS.md, .claude/skills/, .claude/agents/.
#
# The `--i-understand-...` guardrail flag is implicit when running inside
# Docker — running this image is itself the explicit consent.

set -eu

PROJECT_DIR="${PROJECT_DIR:-/project}"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-/workspace}"

if [ -f "$PROJECT_DIR/WORKFLOW.md" ]; then
  WORKFLOW_PATH="$PROJECT_DIR/WORKFLOW.md"
else
  WORKFLOW_PATH="/etc/opal/default-WORKFLOW.md"
fi

mkdir -p "$WORKSPACE_ROOT"
cd "$PROJECT_DIR"

exec /usr/local/bin/opal \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  "$@" \
  "$WORKFLOW_PATH"
