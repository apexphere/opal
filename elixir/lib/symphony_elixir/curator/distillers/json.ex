defmodule SymphonyElixir.Curator.Distillers.Json do
  @moduledoc """
  Shared JSON fence parser for curator distillers.

  Extracts a single ```json ... ``` fence from a raw `claude -p` response and
  builds a `Proposal` from the decoded payload. Both `Distillers.Article` and
  `Distillers.VerifyLog` share this output contract.
  """

  alias SymphonyElixir.Curator.Proposal
  alias SymphonyElixir.Wiki.Entry

  @spec parse_output(String.t()) :: {:ok, Proposal.t()} | {:error, term()}
  def parse_output(raw) when is_binary(raw) do
    with {:ok, json} <- extract_json_fence(raw),
         {:ok, payload} <- Jason.decode(json) do
      build_proposal(payload, raw)
    end
  end

  defp extract_json_fence(raw) do
    case Regex.run(~r/```json\s*\n([\s\S]*?)\n```/, raw, capture: :all_but_first) do
      [json] -> {:ok, json}
      _ -> {:error, :missing_json_fence}
    end
  end

  defp build_proposal(%{"decision" => "reject"} = payload, raw) do
    {:ok,
     Proposal.reject(Map.get(payload, "rationale", "rejected"),
       raw_response: raw
     )}
  end

  defp build_proposal(%{"decision" => "create"} = payload, raw) do
    entry = %Entry{
      slug: Map.get(payload, "slug", ""),
      title: Map.get(payload, "title", ""),
      topic: Map.get(payload, "topic", ""),
      revision: 1,
      created_at: "1970-01-01T00:00:00Z",
      updated_at: "1970-01-01T00:00:00Z",
      sources: [],
      related: [],
      confidence: Map.get(payload, "confidence", "medium"),
      status: "active",
      body: Map.get(payload, "body", "")
    }

    {:ok, Proposal.create(entry, Map.get(payload, "rationale", "created"), raw_response: raw)}
  end

  defp build_proposal(%{"decision" => "refine"} = payload, raw) do
    target_slug = Map.get(payload, "target_slug", "")
    merged_body = Map.get(payload, "merged_body", "")

    {:ok, Proposal.refine(target_slug, merged_body, Map.get(payload, "rationale", "refined"), raw_response: raw)}
  end

  defp build_proposal(payload, _raw) do
    {:error, {:unknown_decision, Map.get(payload, "decision")}}
  end
end
