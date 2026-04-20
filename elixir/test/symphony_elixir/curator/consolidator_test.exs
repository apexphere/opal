defmodule SymphonyElixir.Curator.ConsolidatorTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Curator.{Consolidator, Proposal}
  alias SymphonyElixir.Wiki.Entry

  defp entry(slug) do
    %Entry{
      slug: slug,
      title: "T #{slug}",
      topic: "t",
      revision: 1,
      created_at: "2026-04-20T00:00:00Z",
      updated_at: "2026-04-20T00:00:00Z",
      body: "b"
    }
  end

  describe "producer :reject wins regardless of critic" do
    test "against :approve" do
      proposal = Proposal.reject("off topic")
      final = Consolidator.decide(proposal, :approve)

      assert final.decision == :reject
      assert final.final_decision == :reject
      assert final.producer_decision == :reject
      assert final.critic_verdict == :approve
    end

    test "against {:reject, reason}" do
      proposal = Proposal.reject("off topic")
      final = Consolidator.decide(proposal, {:reject, "also off topic"})

      assert final.decision == :reject
      assert final.critic_verdict == {:reject, "also off topic"}
    end

    test "against {:conflict, slug, reason}" do
      proposal = Proposal.reject("off topic")
      final = Consolidator.decide(proposal, {:conflict, "other", "contradicts"})

      assert final.decision == :reject
      assert final.critic_verdict == {:conflict, "other", "contradicts"}
    end
  end

  describe "critic {:reject, reason} overrides producer create/refine" do
    test "overrides :create" do
      proposal = Proposal.create(entry("alpha"), "novel")
      final = Consolidator.decide(proposal, {:reject, "one-off observation"})

      assert final.decision == :reject
      assert final.final_decision == :reject
      assert final.producer_decision == {:create, "alpha", entry("alpha")}
      assert final.rationale == "critic rejected: one-off observation"
    end

    test "overrides :refine" do
      proposal = Proposal.refine("alpha", "merged", "dup")
      final = Consolidator.decide(proposal, {:reject, "critic disagrees"})

      assert final.decision == :reject
      assert final.rationale == "critic rejected: critic disagrees"
    end
  end

  describe "critic :approve lets the producer's proposal stand" do
    test "passes :create through" do
      proposal = Proposal.create(entry("alpha"), "novel")
      final = Consolidator.decide(proposal, :approve)

      assert {:create, "alpha", _} = final.decision
      assert final.critic_verdict == :approve
      assert final.producer_decision == final.final_decision
    end

    test "passes :refine through" do
      proposal = Proposal.refine("alpha", "merged", "dup")
      final = Consolidator.decide(proposal, :approve)

      assert {:refine, "alpha", "merged"} = final.decision
      assert final.critic_verdict == :approve
    end
  end

  describe "critic :conflict routes to :human_review" do
    test ":create with :conflict — novel topic that contradicts existing" do
      proposal = Proposal.create(entry("alpha"), "novel")
      verdict = {:conflict, "other", "contradicts other"}

      final = Consolidator.decide(proposal, verdict)

      assert {:human_review, producer, ^verdict} = final.decision
      assert {:create, "alpha", _entry} = producer
      assert final.critic_verdict == verdict
    end

    test ":refine(slug) with :conflict(slug) — self-contradicting refine" do
      proposal = Proposal.refine("alpha", "merged", "dup")
      verdict = {:conflict, "alpha", "self-contradicting"}

      final = Consolidator.decide(proposal, verdict)

      assert {:human_review, {:refine, "alpha", "merged"}, ^verdict} = final.decision
    end

    test ":refine(s1) with :conflict(s2) — cross-entry conflict" do
      proposal = Proposal.refine("s1", "merged", "dup")
      verdict = {:conflict, "s2", "cross-entry contradiction"}

      final = Consolidator.decide(proposal, verdict)

      assert {:human_review, {:refine, "s1", "merged"}, ^verdict} = final.decision
    end
  end
end
