defmodule Mix.Tasks.Opal.ReviewTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureIO

  alias Mix.Tasks.Opal.Review, as: ReviewTask
  alias SymphonyElixir.Curator.Proposal
  alias SymphonyElixir.Curator.Queue.ReviewQueue
  alias SymphonyElixir.Wiki.Entry

  @project "github_apexphere_opal-review-task"

  setup do
    Mix.Task.reenable("opal.review")

    test_root =
      Path.join(
        System.tmp_dir!(),
        "opal-review-task-#{System.unique_integer([:positive])}"
      )

    knowledge_root = Path.join(test_root, "knowledge")
    File.mkdir_p!(knowledge_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "apexphere/opal-review-task",
      knowledge_root: knowledge_root
    )

    on_exit(fn -> File.rm_rf(test_root) end)

    %{test_root: test_root}
  end

  defp create_proposal(slug) do
    entry = %Entry{
      slug: slug,
      title: "T",
      topic: "t",
      revision: 1,
      created_at: "2026-04-20T00:00:00Z",
      updated_at: "2026-04-20T00:00:00Z",
      body: "# body\n\nhello\n"
    }

    hr_decision = {:human_review, {:create, slug, entry}, {:conflict, "other", "contradicts"}}

    %Proposal{
      decision: hr_decision,
      producer_decision: {:create, slug, entry},
      critic_verdict: {:conflict, "other", "contradicts"},
      final_decision: hr_decision,
      rationale: "r",
      source_ref: "ref",
      raw_response: nil
    }
  end

  defp reject_proposal do
    %Proposal{
      decision: :reject,
      producer_decision: :reject,
      critic_verdict: :approve,
      final_decision: :reject,
      rationale: "r",
      source_ref: nil,
      raw_response: nil
    }
  end

  defp refine_proposal(slug, body) do
    hr_decision = {:human_review, {:refine, slug, body}, {:conflict, "x", "contradicts"}}

    %Proposal{
      decision: hr_decision,
      producer_decision: {:refine, slug, body},
      critic_verdict: {:conflict, "x", "contradicts"},
      final_decision: hr_decision,
      rationale: "r",
      source_ref: "ref",
      raw_response: nil
    }
  end

  test "prints help" do
    output = capture_io(fn -> ReviewTask.run(["--help"]) end)
    assert output =~ "mix opal.review"
  end

  test "fails on invalid options" do
    assert_raise Mix.Error, ~r/Invalid option/, fn -> ReviewTask.run(["--wat"]) end
  end

  test "prints a friendly message when the queue is empty" do
    output =
      capture_io(fn ->
        ReviewTask.run(["--project", @project])
      end)

    assert output =~ "No parked proposals"
  end

  test "dry-run summarizes every parked proposal without prompting" do
    :ok = ReviewQueue.park(@project, create_proposal("alpha"))
    :ok = ReviewQueue.park(@project, refine_proposal("beta", "merged body\n"))
    :ok = ReviewQueue.park(@project, reject_proposal())

    output =
      capture_io(fn ->
        ReviewTask.run(["--project", @project, "--dry-run"])
      end)

    assert output =~ "Draining 3 parked proposal"
    assert output =~ "producer=create alpha"
    assert output =~ "producer=refine beta"
    assert output =~ "REJECT"
    # Dry-run must not delete.
    assert length(ReviewQueue.list(@project)) == 3
  end

  test "interactive drain deletes files that are quit-through" do
    :ok = ReviewQueue.park(@project, create_proposal("gamma"))

    # "q\n" at the human_review prompt → :quit → file is still deleted
    # (the human saw it and moved on).
    output =
      capture_io("q\n", fn ->
        ReviewTask.run(["--project", @project])
      end)

    assert output =~ "HUMAN REVIEW"
    assert output =~ "Resolved (quit)"
    assert ReviewQueue.list(@project) == []
  end

  test "accept on human_review writes the underlying producer proposal and deletes the file" do
    :ok = ReviewQueue.park(@project, create_proposal("delta"))

    output =
      capture_io("a\n", fn ->
        ReviewTask.run(["--project", @project])
      end)

    assert output =~ "HUMAN REVIEW"
    assert output =~ "Resolved (accepted)"
    assert SymphonyElixir.Wiki.exists?(@project, "delta")
    assert ReviewQueue.list(@project) == []
  end

  test "corrupt parked file is reported and left on disk" do
    dir = ReviewQueue.queue_dir(@project)
    File.mkdir_p!(dir)
    bad = Path.join(dir, "bad.json")
    File.write!(bad, "{not json")

    output =
      capture_io(:stderr, fn ->
        ReviewTask.run(["--project", @project])
      end)

    assert output =~ "Could not read"
    assert File.exists?(bad)
  end

  test "describes human_review summaries across producer and verdict shapes" do
    # Cover the summary helpers directly through dry-run. Note: the
    # consolidator never produces {:human_review, :reject, _} (reject wins
    # short-circuit), so that variant is not exercised here.
    entry = %Entry{
      slug: "e",
      title: "T",
      topic: "t",
      revision: 1,
      created_at: "2026-04-20T00:00:00Z",
      updated_at: "2026-04-20T00:00:00Z",
      body: "b"
    }

    variants = [
      %Proposal{
        decision: {:human_review, {:create, "c", entry}, {:reject, "bad"}},
        producer_decision: {:create, "c", entry},
        critic_verdict: {:reject, "bad"},
        final_decision: {:human_review, {:create, "c", entry}, {:reject, "bad"}},
        rationale: "r",
        source_ref: nil,
        raw_response: nil
      },
      %Proposal{
        decision: {:human_review, {:refine, "r1", "b"}, :approve},
        producer_decision: {:refine, "r1", "b"},
        critic_verdict: :approve,
        final_decision: {:human_review, {:refine, "r1", "b"}, :approve},
        rationale: "r",
        source_ref: nil,
        raw_response: nil
      },
      %Proposal{
        decision: {:human_review, {:refine, "r2", "b"}, nil},
        producer_decision: {:refine, "r2", "b"},
        critic_verdict: nil,
        final_decision: {:human_review, {:refine, "r2", "b"}, nil},
        rationale: "r",
        source_ref: nil,
        raw_response: nil
      }
    ]

    Enum.each(variants, &ReviewQueue.park(@project, &1))

    output =
      capture_io(fn ->
        ReviewTask.run(["--project", @project, "--dry-run"])
      end)

    assert output =~ "producer=create c"
    assert output =~ "producer=refine r1"
    assert output =~ "verdict=approve"
    assert output =~ "verdict=reject"
    assert output =~ "verdict=(none)"
  end

  test "dry-run summarizes bare CREATE and REFINE proposals" do
    entry = %Entry{
      slug: "bare-create",
      title: "T",
      topic: "t",
      revision: 1,
      created_at: "2026-04-20T00:00:00Z",
      updated_at: "2026-04-20T00:00:00Z",
      body: "b"
    }

    bare_create = %Proposal{
      decision: {:create, "bare-create", entry},
      producer_decision: {:create, "bare-create", entry},
      critic_verdict: :approve,
      final_decision: {:create, "bare-create", entry},
      rationale: "r",
      source_ref: nil,
      raw_response: nil
    }

    bare_refine = %Proposal{
      decision: {:refine, "bare-refine", "body"},
      producer_decision: {:refine, "bare-refine", "body"},
      critic_verdict: :approve,
      final_decision: {:refine, "bare-refine", "body"},
      rationale: "r",
      source_ref: nil,
      raw_response: nil
    }

    :ok = ReviewQueue.park(@project, bare_create)
    :ok = ReviewQueue.park(@project, bare_refine)

    output =
      capture_io(fn ->
        ReviewTask.run(["--project", @project, "--dry-run"])
      end)

    assert output =~ "CREATE bare-create"
    assert output =~ "REFINE bare-refine"
  end

  test "reports review errors without deleting the parked file" do
    # Park a refine proposal whose target doesn't exist in the wiki. The
    # non-human_review refine path calls Wiki.get first and surfaces
    # {:error, :not_found}. The file must remain.
    plain_refine = %Proposal{
      decision: {:refine, "missing-slug", "body\n"},
      producer_decision: {:refine, "missing-slug", "body\n"},
      critic_verdict: :approve,
      final_decision: {:refine, "missing-slug", "body\n"},
      rationale: "r",
      source_ref: "ref",
      raw_response: nil
    }

    :ok = ReviewQueue.park(@project, plain_refine)

    output =
      capture_io(:stderr, fn ->
        capture_io("a\n", fn ->
          ReviewTask.run(["--project", @project])
        end)
      end)

    assert output =~ "Review failed"
    assert length(ReviewQueue.list(@project)) == 1
  end
end
