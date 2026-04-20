defmodule SymphonyElixir.Curator.ProposalTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Curator.Proposal
  alias SymphonyElixir.Wiki.Entry

  defp build_entry(slug) do
    %Entry{
      slug: slug,
      title: "T",
      topic: "topic",
      revision: 1,
      created_at: "2026-04-20T00:00:00Z",
      updated_at: "2026-04-20T00:00:00Z",
      body: "b"
    }
  end

  test "reject/2 builds a :reject proposal with rationale" do
    p = Proposal.reject("not relevant", source_ref: "x.md")
    assert p.decision == :reject
    assert p.producer_decision == :reject
    assert p.final_decision == :reject
    assert p.critic_verdict == nil
    assert p.rationale == "not relevant"
    assert p.source_ref == "x.md"
  end

  test "create/3 builds a {:create, slug, entry} proposal" do
    entry = build_entry("alpha")
    p = Proposal.create(entry, "novel topic")
    assert {:create, "alpha", ^entry} = p.decision
    assert {:create, "alpha", ^entry} = p.producer_decision
    assert {:create, "alpha", ^entry} = p.final_decision
    assert p.rationale == "novel topic"
  end

  test "refine/4 builds a {:refine, slug, body} proposal" do
    p = Proposal.refine("alpha", "new body", "duplicate")
    assert {:refine, "alpha", "new body"} = p.decision
    assert {:refine, "alpha", "new body"} = p.producer_decision
    assert {:refine, "alpha", "new body"} = p.final_decision
    assert p.rationale == "duplicate"
  end

  test "preserves raw_response when provided" do
    p = Proposal.reject("x", raw_response: "raw text")
    assert p.raw_response == "raw text"
  end

  describe "with_final/3" do
    test "overrides final_decision and critic_verdict but preserves producer_decision" do
      entry = build_entry("alpha")
      proposal = Proposal.create(entry, "novel")

      critic_verdict = {:conflict, "other", "contradicts other"}
      human_review = {:human_review, proposal.producer_decision, critic_verdict}

      updated = Proposal.with_final(proposal, human_review, critic_verdict)

      assert updated.decision == human_review
      assert updated.final_decision == human_review
      assert updated.critic_verdict == critic_verdict
      assert updated.producer_decision == {:create, "alpha", entry}
    end
  end
end
