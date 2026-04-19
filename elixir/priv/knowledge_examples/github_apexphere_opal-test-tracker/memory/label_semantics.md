---
name: Label semantics for opal-test-tracker
description: How Opal maps issue state to GitHub labels on this repo
type: reference
---

The tracker adapter encodes issue state as labels, not a native field.

**Mapping:**
- `todo` label → `Todo` state
- `in-progress` label → `In Progress` state
- `human-review` label → awaiting human review
- issue closed → `Done` state (no terminal label; closure is the signal)

**Why:** GitHub Issues has no native state machine beyond open/closed. Labels
are the closest thing to a state field that's queryable via the REST API.

**How to apply:** Transitions swap labels atomically — remove the old state
label, add the new. Never leave two state labels on one issue. When moving
to Done, close the issue and remove all state labels.
