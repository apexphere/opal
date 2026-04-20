defmodule SymphonyElixir.Curator.Critic do
  @moduledoc """
  Behaviour for the curator's independent second-opinion step.

  The critic sees the same inputs as the distiller (article body, entry
  summaries, candidate bodies) and returns one of:

    * `:approve` — no contradiction with existing knowledge.
    * `{:reject, reason}` — this article should not enter the wiki at all.
    * `{:conflict, slug, reason}` — contradicts existing entry `slug`.

  The critic never proposes a concrete merge; it only raises flags. The
  consolidator turns those flags plus the distiller's proposal into a final
  decision (see `SymphonyElixir.Curator.Consolidator`).

  Implementations:

    * `SymphonyElixir.Curator.Critics.Consistency` — invokes `claude -p`.
    * `SymphonyElixir.Curator.Critics.Stub`        — reads a recorded verdict.
  """

  alias SymphonyElixir.Wiki.Entry

  @type verdict ::
          :approve
          | {:reject, String.t()}
          | {:conflict, slug :: String.t(), reason :: String.t()}

  @callback critique(
              article_body :: String.t(),
              summaries :: [Entry.summary()],
              candidates :: [Entry.t()]
            ) :: {:ok, verdict()} | {:error, term()}
end
