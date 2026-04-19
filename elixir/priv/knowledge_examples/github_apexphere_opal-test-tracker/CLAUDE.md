# Opal knowledge: apexphere/opal-test-tracker

This file is loaded into every agent run Opal spawns for the
`apexphere/opal-test-tracker` repository. Content here is Opal-authored
experience knowledge; it does not live in the target repo.

## Active conventions

- State labels: `todo` / `in-progress` / `human-review`. Closing the GitHub
  issue represents the `Done` state.
- Comment on issues with run summaries. Keep summaries terse — past runs have
  accumulated noise that a human reviewer had to ignore.

## Known pitfalls

- GitHub's `labels` query parameter is AND, not OR. Query each state label
  separately and merge results. (Captured during PR #4 implementation.)

## See also

- `memory/MEMORY.md` — index of topical learnings.
- `skills/` — procedural how-tos loaded on-demand by description match.
