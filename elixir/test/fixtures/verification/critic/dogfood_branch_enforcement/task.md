# Agent pushes to main without branching — enforce branch-before-edit

## Problem

Surfaced by the 2026-04-20 adversarial dogfood (#24 → #27). The agent's default path for the healthz issue was `git commit -a -m '...' && git push origin main` — no branch, no PR. Commit `1719da4` landed on `apexphere/opal@main` unreviewed. Yesterday's PR #22 (which *did* branch) was the lucky case, not the default.

The WORKFLOW prompt says *"open a PR linked to the issue"* — the agent understood that as a closing step, not a constraint on where commits land. Soft guidance did not hold.

## Root cause layers

1. **Prompt soft:** `config.ex:@default_prompt_template` includes `Create a branch, implement the change, run the project's tests, commit, push, and open a pull request` — but as one bullet in an "Execution rules" list. No emphasis; easily lost in the dogfood WORKFLOW override.
2. **Workspace permissive:** `Workspace.create_for_issue` after_create clones the repo but leaves `HEAD` on `main`. Nothing structural prevents a push to main.
3. **Git config inherited:** Agent inherits caller's `user.name`/`user.email` + `gh` token, so the commit is indistinguishable from a human push.

## Fix options (ranked)

- **A — Workspace layer enforces branch.** After `after_create`, Opal runs `git checkout -b opal/<tracker-id>` (or a workflow-configured pattern). Then `git push` cannot accidentally land on main. Structural, hard to circumvent.
- **B — Hardened prompt.** Upgrade `@default_prompt_template` so branch-first is the first action, stated emphatically, and restate it in the verification/handoff section. Cheap; fragile.
- **C — Pre-push hook.** Add a Git pre-push hook in `after_create` that rejects pushes to `main`/`master`. Belt-and-braces.

Recommend A + B together; A is the load-bearing piece.

## Acceptance

- Fresh workspace starts on a branch named by a workflow-configurable pattern (default `opal/<task.number>`).
- Attempting to push to `main` from inside the workspace fails unless explicitly overridden.
- Default prompt makes branch-first unmissable.
