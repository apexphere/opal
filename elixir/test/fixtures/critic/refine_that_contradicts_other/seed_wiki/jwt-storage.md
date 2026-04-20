---
slug: jwt-storage
title: Where to store JWTs in the browser
topic: security/auth
revision: 1
created_at: 2026-04-19T10:00:00Z
updated_at: 2026-04-19T10:00:00Z
confidence: high
status: active
sources:
  - kind: article
    ref: feeds/jwt-storage.md
    ingested_at: 2026-04-19T10:00:00Z
related: []
---
# JWT storage

Store JWTs in HttpOnly, Secure, SameSite=Strict cookies. localStorage is
vulnerable to XSS exfiltration and should never hold session tokens.
