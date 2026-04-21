Fresh Opal workspaces must auto-branch to `opal/<id>` the first time `Workspace.create_for_issue/2` clones the repo for an issue.

The user-visible behaviour: after `create_for_issue` returns, running `git branch --show-current` inside the workspace must print `opal/<id>` (or the configured `workspace.branch_pattern`), not `main`. Existing workspaces are untouched; only fresh clones get the new branch.
