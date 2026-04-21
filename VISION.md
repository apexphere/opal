# Vision

**Opal is a self-evolving agent on a Claude subscription, designed to work in any domain.** It starts by learning, improves by doing, and becomes trustworthy enough to walk away from.

This document is the north star for Opal's development. When scoping a feature, ask which pillar it serves. Proposals that don't serve self-verifying, self-learning, or subscription-native are probably not vision-critical.

## Customer

A solo developer on a Claude Max subscription. One person, many projects over a career.

## Step-change

Today, using Claude Code means paying two taxes:

- **Verification tax** — re-checking every claimed completion, because CC never tests its own work.
- **Re-orientation tax** — re-briefing the agent after every break, because the agent never learns your project. Every session starts fresh.

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

### 2. Self-learning

Opal gets better at your project by working on it.

> Knowledge needs to grow, settle, and refine. Do not think knowledge is plain memory.

Karpathy's LLM wiki pattern is the compass: compile knowledge once, keep it current, maintain through review rather than re-derive per query. Treat it as guidance for direction, not a blueprint for implementation.

Every run produces signal — what the agent tried, what verification caught, what the human corrected. A curator distills that signal into a living per-project knowledge layer: domain facts, codebase idioms, and behavioural guidance. The next run reads the current layer before acting.

Self-verifying is the teacher. Self-learning is the student. The loop is the product.

The auto-curator is the distillation engine and the real self-evolution loop. Without it the layer accumulates noise; with it, competence compounds. Not model-level learning — no fine-tuning, no weight updates. All learning lives in the knowledge layer, which is readable, editable, and per-project.

### 3. Subscription-native

Everything goes through `claude -p`. No direct Anthropic SDK calls. No hidden token spend.

Wrapping the CLI — not the API — is the economic moat. This is not generic "pluggable runtime" extensibility; it is the load-bearing economic choice.

## Self-evolving

Competence compounds in the **knowledge layer**, not in the orchestrator. Logic stays static; the layer grows, settles, refines. An older Opal on a project is a smarter Opal on that project — because the layer is denser *and* more distilled.

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

Opal turns a coding agent from a fresh-start tool into a long-lived domain operator that verifies its own work and learns the project — one per project, for the life of the project.
