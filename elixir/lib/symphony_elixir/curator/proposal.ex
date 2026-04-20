defmodule SymphonyElixir.Curator.Proposal do
  @moduledoc """
  Curator's structured output for one article: reject, create, refine,
  or human_review.

  Slugs in this struct are *authoritative*. The LLM is allowed to suggest a
  slug only on the `create` path (where there is no input slug to anchor to);
  on `refine`, the input slug from the relevance step wins — the LLM's slug
  field is discarded by the curator. See VISION.md and the prompt-injection
  fixture for the rationale.

  Phase 2 adds a second-opinion critic. Every proposal now carries three
  decision views:

    * `producer_decision` — what the distiller (first LLM) proposed.
    * `critic_verdict`   — what the independent critic reported.
    * `final_decision`   — what the consolidator merged into.

  `decision` is kept as an alias for `final_decision` so consumers that
  already match on `proposal.decision` (the review CLI, eval harness) work
  unchanged.
  """

  alias SymphonyElixir.Wiki.Entry

  @type producer_decision ::
          :reject
          | {:create, slug :: String.t(), Entry.t()}
          | {:refine, slug :: String.t(), merged_body :: String.t()}

  @type critic_verdict ::
          :approve
          | {:reject, String.t()}
          | {:conflict, slug :: String.t(), reason :: String.t()}
          | nil

  @type final_decision ::
          :reject
          | {:create, slug :: String.t(), Entry.t()}
          | {:refine, slug :: String.t(), merged_body :: String.t()}
          | {:human_review, producer_decision(), critic_verdict()}

  @type decision :: final_decision()

  @enforce_keys [:decision, :rationale]
  defstruct decision: nil,
            producer_decision: nil,
            critic_verdict: nil,
            final_decision: nil,
            rationale: "",
            source_ref: nil,
            raw_response: nil

  @type t :: %__MODULE__{
          decision: final_decision(),
          producer_decision: producer_decision() | nil,
          critic_verdict: critic_verdict(),
          final_decision: final_decision(),
          rationale: String.t(),
          source_ref: String.t() | nil,
          raw_response: String.t() | nil
        }

  @spec reject(String.t(), keyword()) :: t()
  def reject(rationale, opts \\ []) do
    new(:reject, rationale, opts)
  end

  @spec create(Entry.t(), String.t(), keyword()) :: t()
  def create(%Entry{} = entry, rationale, opts \\ []) do
    new({:create, entry.slug, entry}, rationale, opts)
  end

  @spec refine(String.t(), String.t(), String.t(), keyword()) :: t()
  def refine(slug, merged_body, rationale, opts \\ [])
      when is_binary(slug) and is_binary(merged_body) do
    new({:refine, slug, merged_body}, rationale, opts)
  end

  @doc """
  Overrides the final decision after consolidation (e.g. human_review or a
  critic-forced reject) while preserving the producer's original decision
  for audit.
  """
  @spec with_final(t(), final_decision(), critic_verdict()) :: t()
  def with_final(%__MODULE__{} = proposal, final_decision, critic_verdict) do
    %__MODULE__{
      proposal
      | decision: final_decision,
        final_decision: final_decision,
        critic_verdict: critic_verdict
    }
  end

  defp new(decision, rationale, opts) do
    %__MODULE__{
      decision: decision,
      producer_decision: decision,
      final_decision: decision,
      critic_verdict: nil,
      rationale: rationale,
      source_ref: Keyword.get(opts, :source_ref),
      raw_response: Keyword.get(opts, :raw_response)
    }
  end
end
