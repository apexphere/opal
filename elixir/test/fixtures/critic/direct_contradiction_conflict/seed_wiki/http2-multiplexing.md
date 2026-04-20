---
slug: http2-multiplexing
title: HTTP/2 multiplexing removes the need for domain sharding
topic: http/2
revision: 1
created_at: 2026-04-19T10:00:00Z
updated_at: 2026-04-19T10:00:00Z
confidence: high
status: active
sources:
  - kind: article
    ref: feeds/http2.md
    ingested_at: 2026-04-19T10:00:00Z
related: []
---
# HTTP/2 multiplexing

HTTP/2 multiplexes many requests over one TCP connection. Domain sharding
— once a common workaround for HTTP/1.1's six-connection-per-host limit —
is no longer necessary and actually hurts performance by defeating
multiplexing.
