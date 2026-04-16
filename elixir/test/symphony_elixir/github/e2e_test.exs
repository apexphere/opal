defmodule SymphonyElixir.Github.E2ETest do
  @moduledoc """
  End-to-end tests for the GitHub tracker adapter against a real GitHub repo.
  Requires GITHUB_TOKEN env var and the test repo apexphere/opal-test-tracker.

  Run with: mix test test/symphony_elixir/github/e2e_test.exs --include e2e
  """
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Github.Adapter
  alias SymphonyElixir.Linear.Issue

  @test_repo "apexphere/opal-test-tracker"

  @moduletag :e2e

  setup do
    token = System.get_env("GITHUB_TOKEN")

    if is_nil(token) do
      raise "GITHUB_TOKEN env var required for e2e tests"
    end

    workflow_root =
      Path.join(System.tmp_dir!(), "symphony-github-e2e-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workflow_root)
    workflow_file = Path.join(workflow_root, "WORKFLOW.md")

    write_workflow_file!(workflow_file,
      tracker_kind: "github",
      tracker_api_token: token,
      tracker_project_slug: nil,
      tracker_repo: @test_repo,
      tracker_labels_prefix: ""
    )

    SymphonyElixir.Workflow.set_workflow_file_path(workflow_file)
    if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()

    on_exit(fn ->
      File.rm_rf(workflow_root)
    end)

    :ok
  end

  describe "fetch_candidate_issues/0" do
    test "fetches open issues from GitHub" do
      assert {:ok, issues} = Adapter.fetch_candidate_issues()
      assert is_list(issues)
      assert length(issues) >= 2

      issue = Enum.find(issues, &(&1.identifier == "#1"))
      assert %Issue{} = issue
      assert issue.id == "1"
      assert issue.title == "Add user authentication"
      assert issue.description =~ "login/logout"
      assert issue.state in ["Todo", "In Progress", "Human Review"]
      assert issue.url =~ "github.com"
      assert issue.branch_name == "issue-1"
    end
  end

  describe "fetch_issues_by_states/1" do
    test "fetches issues in Todo state" do
      assert {:ok, issues} = Adapter.fetch_issues_by_states(["Todo"])
      assert is_list(issues)

      todo_issues = Enum.filter(issues, &(&1.state == "Todo"))
      assert length(todo_issues) >= 1
    end

    test "fetches issues in In Progress state" do
      assert {:ok, issues} = Adapter.fetch_issues_by_states(["In Progress"])
      assert is_list(issues)

      in_progress = Enum.filter(issues, &(&1.state == "In Progress"))
      assert length(in_progress) >= 1
    end

    test "returns empty for states with no issues" do
      assert {:ok, issues} = Adapter.fetch_issues_by_states(["Human Review"])
      human_review = Enum.filter(issues, &(&1.state == "Human Review"))
      assert human_review == []
    end
  end

  describe "fetch_issue_states_by_ids/1" do
    test "fetches specific issues by number" do
      assert {:ok, issues} = Adapter.fetch_issue_states_by_ids(["1", "2"])
      assert length(issues) == 2

      ids = Enum.map(issues, & &1.id)
      assert "1" in ids
      assert "2" in ids
    end

    test "skips nonexistent issues" do
      assert {:ok, issues} = Adapter.fetch_issue_states_by_ids(["99999"])
      assert issues == []
    end
  end

  describe "create_comment/2" do
    test "posts a comment on an issue" do
      comment_body = "E2E test comment at #{DateTime.utc_now() |> DateTime.to_iso8601()}"
      assert :ok = Adapter.create_comment("1", comment_body)
    end
  end

  describe "update_issue_state/2" do
    test "transitions issue from Todo to In Progress and back" do
      # Issue #3 starts as Todo
      assert {:ok, [issue]} = Adapter.fetch_issue_states_by_ids(["3"])
      original_state = issue.state

      # Transition to In Progress
      assert :ok = Adapter.update_issue_state("3", "In Progress")
      Process.sleep(1_000)

      assert {:ok, [updated]} = Adapter.fetch_issue_states_by_ids(["3"])
      assert updated.state == "In Progress"

      # Transition back to original state
      assert :ok = Adapter.update_issue_state("3", original_state)
      Process.sleep(1_000)

      assert {:ok, [restored]} = Adapter.fetch_issue_states_by_ids(["3"])
      assert restored.state == original_state
    end
  end
end
