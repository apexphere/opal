defmodule SymphonyElixir.Critic.Fallback do
  @moduledoc """
  Shared primitives for the "try Codex, fall through to Claude Code on quota
  exhaustion" pattern used by producer-critic call sites (currently
  `Verification.Critic`; `Curator.Critics.Codex` is a future adopter).

  When a Codex subscription is quota-exhausted, `codex exec` exits 0 with a
  telltale stdout banner and no output file — indistinguishable from a real
  failure at the protocol level. Without detection the caller's fail-open
  policy swallows the signal silently.

  This module owns two small concerns:

    * `quota_exhausted?/1` — predicate over Codex stdout
    * `run_with_cc_fallback/2` — runs a Codex-invoking thunk first; on
      `{:error, :rate_limited}` runs a Claude-invoking thunk as fallback.

  Prompt construction, schema handling, and output parsing are deliberately
  left to the caller — the helper is just the detection + fallback seam.
  """

  require Logger

  @rate_limit_phrases [
    "you've hit your usage limit",
    "upgrade to pro",
    "purchase more credits"
  ]

  @min_phrase_matches 2

  @doc """
  Returns true when `stdout` contains the Codex usage-limit signature.

  Requires at least #{@min_phrase_matches} of the known phrases to match
  (case-insensitive substring) — a single match is too broad given that
  Codex occasionally echoes prompt content into stdout, which could
  include e.g. recipe text that mentions "Upgrade to Pro" in an unrelated
  context. The canonical banner carries all three phrases together, so
  2-of-3 preserves detection while killing single-phrase collisions.
  """
  @spec quota_exhausted?(term()) :: boolean()
  def quota_exhausted?(stdout) when is_binary(stdout) do
    down = String.downcase(stdout)
    hits = Enum.count(@rate_limit_phrases, &String.contains?(down, &1))
    hits >= @min_phrase_matches
  end

  def quota_exhausted?(_), do: false

  @doc """
  Runs `codex_fn.()`. If it returns `{:error, :rate_limited}`, logs and runs
  `claude_fn.()` as fallback. All other results pass through untouched.

  Accepts the fallback tradeoff: a same-model-family Claude critic still
  gives more signal than silently fail-open on Codex quota.
  """
  @spec run_with_cc_fallback((-> result), (-> result)) :: result
        when result: {:ok, term()} | {:error, term()}
  def run_with_cc_fallback(codex_fn, claude_fn)
      when is_function(codex_fn, 0) and is_function(claude_fn, 0) do
    case codex_fn.() do
      {:error, :rate_limited} ->
        Logger.info("Codex critic rate-limited; falling back to Claude Code")
        claude_fn.()

      other ->
        other
    end
  end
end
