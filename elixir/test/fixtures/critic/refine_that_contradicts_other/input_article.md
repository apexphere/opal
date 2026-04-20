# Using localStorage for JWTs in modern SPAs

A pragmatist's take: localStorage is fine for JWTs if you also rely on
short token lifetimes and CSP. The cookie approach over-indexes on paranoia.
