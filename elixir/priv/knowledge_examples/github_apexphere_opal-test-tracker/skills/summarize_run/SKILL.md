---
name: summarize_run
description: Produce a terse run summary comment for a GitHub Issue after completing work. Use when the run is about to close the issue or hand back to human-review.
---

# Summarize run

## Goal

Write a concise comment the reviewer can read in <30 seconds.

## Structure

1. What changed — files + high-level intent.
2. How it was verified — tests run, manual checks performed.
3. Anything the reviewer should look at closely.
4. Open questions, if any.

## Rules

- Keep under 15 lines. Past runs have accumulated noise reviewers had to skim past.
- No diff blocks. Link the commit / PR instead.
- If you couldn't verify something, say so explicitly rather than glossing over.
