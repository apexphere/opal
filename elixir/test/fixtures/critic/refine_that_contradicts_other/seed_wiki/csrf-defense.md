---
slug: csrf-defense
title: Defending against CSRF
topic: security/web
revision: 1
created_at: 2026-04-19T10:00:00Z
updated_at: 2026-04-19T10:00:00Z
confidence: high
status: active
sources:
  - kind: article
    ref: feeds/csrf.md
    ingested_at: 2026-04-19T10:00:00Z
related: []
---
# CSRF defense

Use same-site cookies plus a CSRF token tied to the session. Never rely
on localStorage-based tokens alone: an attacker with XSS can forge
requests as the user.
