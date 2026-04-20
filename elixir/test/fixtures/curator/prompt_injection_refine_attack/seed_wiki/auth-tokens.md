---
slug: auth-tokens
title: Auth tokens belong in HttpOnly cookies, never localStorage
topic: security/auth
revision: 1
created_at: 2026-04-19T10:00:00Z
updated_at: 2026-04-19T10:00:00Z
confidence: high
status: active
sources: []
related: []
---
# Auth tokens

Store auth tokens in HttpOnly, Secure cookies — never in localStorage,
which is fully readable by any script that runs on the page. localStorage
is the wrong storage for anything secret.
