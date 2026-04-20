defmodule SymphonyElixir.Curator.Proposal do
  @moduledoc """
  Curator's structured output for one article: reject, create, or refine.

  Slugs in this struct are *authoritative*. The LLM is allowed to suggest a
  slug only on the `create` path (where there is no input slug to anchor to);
  on `refine`, the input slug from the relevance step wins — the LLM's slug
  field is discarded by the curator. See VISION.md and the prompt-injection
  fixture for the rationale.
  """

  alias SymphonyElixir.Wiki.Entry

  @type decision ::
          :reject
          | {:create, slug :: String.t(), Entry.t()}
          | {:refine, slug :: String.t(), merged_body :: String.t()}

  @enforce_keys [:decision, :rationale]
  defstruct decision: nil,
            rationale: "",
            source_ref: nil,
            raw_response: nil

  @type t :: %__MODULE__{
          decision: decision(),
          rationale: String.t(),
          source_ref: String.t() | nil,
          raw_response: String.t() | nil
        }

  @spec reject(String.t(), keyword()) :: t()
  def reject(rationale, opts \\ []) do
    %__MODULE__{
      decision: :reject,
      rationale: rationale,
      source_ref: Keyword.get(opts, :source_ref),
      raw_response: Keyword.get(opts, :raw_response)
    }
  end

  @spec create(Entry.t(), String.t(), keyword()) :: t()
  def create(%Entry{} = entry, rationale, opts \\ []) do
    %__MODULE__{
      decision: {:create, entry.slug, entry},
      rationale: rationale,
      source_ref: Keyword.get(opts, :source_ref),
      raw_response: Keyword.get(opts, :raw_response)
    }
  end

  @spec refine(String.t(), String.t(), String.t(), keyword()) :: t()
  def refine(slug, merged_body, rationale, opts \\ [])
      when is_binary(slug) and is_binary(merged_body) do
    %__MODULE__{
      decision: {:refine, slug, merged_body},
      rationale: rationale,
      source_ref: Keyword.get(opts, :source_ref),
      raw_response: Keyword.get(opts, :raw_response)
    }
  end
end
