defmodule SymphonyElixir.Curator.Distillers.Stub do
  @moduledoc """
  Distiller that returns a recorded transcript instead of calling `claude -p`.

  Used by the curator fixture eval and unit tests so the pipeline runs
  deterministically and doesn't burn LLM credits.

  Configure via `Application.put_env(:symphony_elixir, :curator_stub_response, response)`
  where `response` is one of:

      :reject
      {:reject, "rationale text"}
      {:create, %{"slug" => "x", "title" => "T", "topic" => "t", "body" => "b"}}
      {:refine, "target-slug", "merged body"}
      {:fn, fn input, summaries, candidates -> {:ok, proposal} end}
  """

  @behaviour SymphonyElixir.Curator.Distiller

  alias SymphonyElixir.Curator.Proposal
  alias SymphonyElixir.Wiki.Entry

  @impl true
  def distill(input, summaries, candidates) do
    case Application.get_env(:symphony_elixir, :curator_stub_response) do
      nil ->
        {:error, :stub_response_not_configured}

      :reject ->
        {:ok, Proposal.reject("stub: rejected")}

      {:reject, rationale} ->
        {:ok, Proposal.reject(rationale)}

      {:create, attrs} ->
        {:ok, build_create(attrs, input)}

      {:refine, slug, merged_body} ->
        {:ok, Proposal.refine(slug, merged_body, "stub: refined #{slug}")}

      {:fn, fun} when is_function(fun, 3) ->
        fun.(input, summaries, candidates)
    end
  end

  defp build_create(attrs, input) do
    entry = %Entry{
      slug: Map.get(attrs, "slug", "stub-entry"),
      title: Map.get(attrs, "title", "Stub Entry"),
      topic: Map.get(attrs, "topic", ""),
      revision: 1,
      created_at: input.ingested_at,
      updated_at: input.ingested_at,
      sources: [],
      related: [],
      confidence: Map.get(attrs, "confidence", "medium"),
      status: Map.get(attrs, "status", "active"),
      body: Map.get(attrs, "body", "")
    }

    Proposal.create(entry, Map.get(attrs, "rationale", "stub: created"))
  end
end
