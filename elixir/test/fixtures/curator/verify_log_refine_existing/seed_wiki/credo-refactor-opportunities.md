---
slug: credo-refactor-opportunities
title: Credo --strict refactor rules (surface area)
topic: elixir/credo
revision: 1
created_at: 2026-04-19T10:00:00Z
updated_at: 2026-04-19T10:00:00Z
confidence: medium
status: active
sources: []
related: []
---
# Credo refactor opportunities

Credo in `--strict` mode flags several refactor opportunities. Common ones:

- `Credo.Check.Refactor.Nesting` — caps nesting at 2.
- `Credo.Check.Refactor.CyclomaticComplexity` — caps branching.

Fix by extracting helpers or reducing branching.
