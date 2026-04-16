defmodule SymphonyElixir.Github.AdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Github.Adapter
  alias SymphonyElixir.Linear.Issue

  defmodule MockGithubClient do
    alias SymphonyElixir.Linear.Issue

    def fetch_candidate_issues do
      send(self(), :mock_fetch_candidate_issues)
      {:ok, [%Issue{id: "1", identifier: "#1", title: "Test issue", state: "Todo", labels: ["todo"]}]}
    end

    def fetch_issues_by_states(states) do
      send(self(), {:mock_fetch_issues_by_states, states})
      {:ok, [%Issue{id: "1", identifier: "#1", title: "Test issue", state: "Todo", labels: ["todo"]}]}
    end

    def fetch_issue_states_by_ids(ids) do
      send(self(), {:mock_fetch_issue_states_by_ids, ids})
      {:ok, [%Issue{id: "1", identifier: "#1", title: "Test issue", state: "Todo", labels: ["todo"]}]}
    end

    def create_comment(issue_id, body) do
      send(self(), {:mock_create_comment, issue_id, body})
      :ok
    end

    def update_issue_state(issue_id, state_name) do
      send(self(), {:mock_update_issue_state, issue_id, state_name})
      :ok
    end

    def add_labels(issue_number, labels) do
      send(self(), {:mock_add_labels, issue_number, labels})
      :ok
    end

    def remove_label(issue_number, label) do
      send(self(), {:mock_remove_label, issue_number, label})
      :ok
    end

    def update_issue(issue_number, attrs) do
      send(self(), {:mock_update_issue, issue_number, attrs})
      :ok
    end
  end

  setup do
    Application.put_env(:symphony_elixir, :github_client_module, MockGithubClient)

    workflow_root =
      Path.join(System.tmp_dir!(), "symphony-github-adapter-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workflow_root)
    workflow_file = Path.join(workflow_root, "WORKFLOW.md")

    write_workflow_file!(workflow_file,
      tracker_kind: "github",
      tracker_api_token: "ghp_test",
      tracker_project_slug: nil,
      tracker_repo: "owner/repo"
    )

    SymphonyElixir.Workflow.set_workflow_file_path(workflow_file)
    if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :github_client_module)
      File.rm_rf(workflow_root)
    end)

    :ok
  end

  describe "fetch_candidate_issues/0" do
    test "delegates to client" do
      assert {:ok, [%Issue{id: "1"}]} = Adapter.fetch_candidate_issues()
      assert_received :mock_fetch_candidate_issues
    end
  end

  describe "fetch_issues_by_states/1" do
    test "delegates to client" do
      assert {:ok, [%Issue{id: "1"}]} = Adapter.fetch_issues_by_states(["Todo"])
      assert_received {:mock_fetch_issues_by_states, ["Todo"]}
    end
  end

  describe "fetch_issue_states_by_ids/1" do
    test "delegates to client" do
      assert {:ok, [%Issue{id: "1"}]} = Adapter.fetch_issue_states_by_ids(["1"])
      assert_received {:mock_fetch_issue_states_by_ids, ["1"]}
    end
  end

  describe "create_comment/2" do
    test "delegates to client" do
      assert :ok = Adapter.create_comment("1", "Hello")
      assert_received {:mock_create_comment, "1", "Hello"}
    end
  end

  describe "update_issue_state/2" do
    test "closes issue when transitioning to Done" do
      assert :ok = Adapter.update_issue_state("1", "Done")
      assert_received {:mock_fetch_issue_states_by_ids, ["1"]}
      assert_received {:mock_remove_label, "1", "todo"}
      assert_received {:mock_update_issue, "1", %{state: "closed"}}
    end

    test "closes issue when transitioning to Closed" do
      assert :ok = Adapter.update_issue_state("1", "Closed")
      assert_received {:mock_update_issue, "1", %{state: "closed"}}
    end

    test "swaps labels when transitioning to In Progress" do
      assert :ok = Adapter.update_issue_state("1", "In Progress")
      assert_received {:mock_fetch_issue_states_by_ids, ["1"]}
      assert_received {:mock_remove_label, "1", "todo"}
      assert_received {:mock_update_issue, "1", %{state: "open"}}
      assert_received {:mock_add_labels, "1", ["in-progress"]}
    end

    test "swaps labels when transitioning to Human Review" do
      assert :ok = Adapter.update_issue_state("1", "Human Review")
      assert_received {:mock_remove_label, "1", "todo"}
      assert_received {:mock_add_labels, "1", ["human-review"]}
    end
  end
end
