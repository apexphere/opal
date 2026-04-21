# Using codex exec with --output-schema

Codex's CLI supports `--output-schema <path>` to constrain the model
response to a JSON schema. Notable quirk: every property listed in
`properties` must also appear in `required` — Codex's validator
does not accept truly-optional properties. To model an optional
field, use a nullable type (`["string", "null"]`) and still list the
field in `required`.

Pass the prompt as a positional argument. Use `-o <path>` to write
the raw JSON body to a file (no fences, no stderr noise). Combine
with `--sandbox read-only --skip-git-repo-check` for invocations
from automation where the working tree is irrelevant.
