defmodule SymphonyElixir.Curator.Distiller do
  @moduledoc """
  Behaviour for the curator's "3-way distillation" step.

  A distiller is given:
    * the article input (body, source ref, ingested timestamp)
    * the project's existing entry summaries
    * the existing entries' full bodies (capped) for refinement context

  It returns a structured `Proposal` (`:reject | {:create, ..} | {:refine, ..}`).

  Implementations:
    * `SymphonyElixir.Curator.Distillers.Article` — invokes `claude -p`.
    * `SymphonyElixir.Curator.Distillers.Stub`   — reads a recorded transcript.
  """

  alias SymphonyElixir.Curator.Proposal
  alias SymphonyElixir.Wiki.Entry

  @type input :: %{
          required(:body) => String.t(),
          required(:source_ref) => String.t(),
          required(:ingested_at) => String.t()
        }

  @type candidate :: Entry.t()

  @callback distill(input(), [Entry.summary()], [candidate()]) ::
              {:ok, Proposal.t()} | {:error, term()}
end
