# Opal — guidance for Claude Code

**Read [VISION.md](VISION.md) first.** It defines what Opal is, who it serves, and the three
pillars (self-verifying, self-remembering, subscription-native) that guide development. Every
feature proposal should answer which pillar it serves.

## Other key docs

- [README.md](README.md) — quickstart and current capabilities
- [SPEC.md](SPEC.md) — language-agnostic specification
- [elixir/README.md](elixir/README.md) — Elixir reference implementation setup

## First principle: pick the next most valuable thing per vision

When asked "what's next" — or whenever choosing what to work on — rank candidates by value to
the vision, not by what's easy, adjacent, or already in the backlog. Read VISION.md, find the
pillar with the largest gap between current state and the bet, and propose work there. A backlog
issue is not evidence of priority; the vision is.

Concretely: do not default to the open-issues list. Compare each pillar in VISION.md against
the current state of the code and capabilities, and explicitly say when the highest-value work
is *not* on the backlog yet (e.g. needs to be filed). If a recommendation does not serve
self-verifying, self-remembering, or subscription-native, say so and offer the vision-aligned
alternative instead.

When discussing "testing," default to user-perspective verification (use the thing the way it was
built to be used), not just unit tests — see VISION.md for the reasoning.
