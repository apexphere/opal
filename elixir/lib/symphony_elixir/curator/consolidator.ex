defmodule SymphonyElixir.Curator.Consolidator do
  @moduledoc """
  Merges a producer proposal and a critic verdict into a final curator
  proposal.

  Matrix:

      producer          critic             final
      reject            *                  reject
      create/refine     reject(reason)     reject
      create            approve            create
      create            conflict(slug)     human_review
      refine(slug_a)    approve            refine(slug_a)
      refine(slug_a)    conflict(slug_b)   human_review

  `human_review` surfaces both views to the operator instead of silently
  accepting a contradictory write.
  """

  alias SymphonyElixir.Curator.{Critic, Proposal}

  @doc """
  Decides the final proposal given the producer's proposal and the critic
  verdict. Pure — no I/O, no side effects.

  The returned proposal has `producer_decision`, `critic_verdict`, and
  `final_decision` all set; `decision` mirrors `final_decision`.
  """
  @spec decide(Proposal.t(), Critic.verdict()) :: Proposal.t()
  def decide(%Proposal{producer_decision: :reject} = proposal, verdict) do
    # Producer's reject wins — cheapest final answer; critic verdict recorded
    # for audit but does not change the outcome.
    Proposal.with_final(proposal, :reject, verdict)
  end

  def decide(%Proposal{} = proposal, {:reject, reason}) do
    updated = Proposal.with_final(proposal, :reject, {:reject, reason})
    %Proposal{updated | rationale: "critic rejected: #{reason}"}
  end

  def decide(%Proposal{producer_decision: producer} = proposal, :approve) do
    Proposal.with_final(proposal, producer, :approve)
  end

  def decide(%Proposal{producer_decision: producer} = proposal, {:conflict, _slug, _reason} = verdict) do
    Proposal.with_final(proposal, {:human_review, producer, verdict}, verdict)
  end
end
