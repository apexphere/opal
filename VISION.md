# Vision

**Opal makes Claude Code trustworthy enough to walk away from.** It verifies its own work, remembers the project across weeks, and runs on a subscription instead of an API bill.

This document is the north star for Opal's development. When scoping a feature, ask which pillar it serves. Proposals that don't serve self-verifying, self-remembering, or subscription-native are probably not vision-critical.

## Customer

A solo developer on a Claude Max subscription. One person, many projects over a career.

## Step-change

Today, using Claude Code means paying two taxes:

- **Verification tax** — re-checking every claimed completion, because CC never tests its own work.
- **Re-orientation tax** — re-briefing the agent after every break, because the agent has no memory of what it's been doing for the last few weeks.

Opal removes both. The developer walks away, comes back, asks *"where are we at, what's next?"*, steers the day's goal, and lets it work.

## The bet

> Many other agents are based on API keys. But I believe someone like me wants to use subscription rather.

Autonomy should be economically free. Metered agents make "let it run overnight" a budget decision; subscription-native agents make it the default.

## Three pillars

### 1. Self-verifying

Before claiming done, Opal uses the thing it just built the way a user would use it.

> "Run the tests" often limits the agent by running unit tests. What we want by testing is from the user's perspective. Test by using the thing being built.

If Opal built the thing, it knows how to use the thing — that knowledge is a byproduct of building, not an external recipe. Self-verification is: *before claiming done, exercise the build the way it was built to be exercised.*

This is the cash-out gate for the other two pillars: remembered context + cheap autonomy + unverified output = fast broken code.

### 2. Self-remembering

A per-project domain wiki that grows with every run.

> Knowledge needs to grow, settle, and refine. Do not think knowledge is plain memory.

Karpathy's LLM wiki pattern is the compass: compile knowledge once, keep it current, maintain through review rather than re-derive per query. Treat it as guidance for direction, not a blueprint for implementation.

The auto-curator is the maintenance engine and the real self-evolution loop — the wiki only compounds if something keeps it current without the human writing every entry.

### 3. Subscription-native

Everything goes through `claude -p`. No direct Anthropic SDK calls. No hidden token spend.

Wrapping the CLI — not the API — is the economic moat. This is not generic "pluggable runtime" extensibility; it is the load-bearing economic choice.

## Self-evolving

Intelligence compounds in the **wiki**, not in the orchestrator. Logic stays static; the knowledge layer grows, settles, refines. An older Opal on a project is a smarter Opal on that project — because the wiki is denser.

Per-project. No cross-project contamination — domains contaminate each other.

Model-level learning (fine-tuning, weights) is out of scope. Evolution happens in the knowledge layer.

## Daily workflow

> My day will start with asking Opal what it did (where we at), what it plans (what we do). I will steer its goal for today. And allow it to get working.

Opal maintains a standing narrative — status + plan — that the human steers each morning. Not logs. A conversation it is ready to have.

## Out of scope

- Teams, multi-human collaboration, review workflows
- API-key-based users, metered billing
- Cross-project knowledge sharing
- A human-first UI for browsing the wiki (the primary reader is Opal itself)
- Model-level learning (fine-tuning, RLHF)

## One-line compression

Opal turns a coding agent from a fresh-start tool into a long-lived, self-verifying domain operator — one per project, for the life of the project.
