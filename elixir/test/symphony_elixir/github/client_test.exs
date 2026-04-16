defmodule SymphonyElixir.Github.ClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Github.Client
  alias SymphonyElixir.Linear.Issue

  defp github_workflow_overrides do
    [
      tracker_kind: "github",
      tracker_api_token: "ghp_test_token",
      tracker_project_slug: nil,
      tracker_endpoint: nil,
      tracker_repo: "owner/repo"
    ]
  end

  defp with_github_config(_context, overrides) do
    workflow_root =
      Path.join(System.tmp_dir!(), "symphony-github-client-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workflow_root)
    workflow_file = Path.join(workflow_root, "WORKFLOW.md")

    base =
      github_workflow_overrides()
      |> Keyword.merge(overrides)

    write_workflow_file!(workflow_file, base)
    SymphonyElixir.Workflow.set_workflow_file_path(workflow_file)
    if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()

    on_exit(fn -> File.rm_rf(workflow_root) end)
    :ok
  end

  defp stub_request(responses) do
    agent = Agent.start_link(fn -> responses end) |> elem(1)

    fun = fn method, path, body ->
      response = Agent.get_and_update(agent, fn
        [next | rest] -> {next, rest}
        [] -> {{:ok, %{status: 500, body: "no more responses"}}, []}
      end)

      send(self(), {:github_api_call, method, path, body})
      response
    end

    Application.put_env(:symphony_elixir, :github_request_fun, fun)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :github_request_fun)
      if Process.alive?(agent), do: Agent.stop(agent)
    end)
  end

  defp sample_github_issue(overrides \\ %{}) do
    Map.merge(
      %{
        "number" => 42,
        "title" => "Fix the widget",
        "body" => "The widget is broken",
        "state" => "open",
        "html_url" => "https://github.com/owner/repo/issues/42",
        "labels" => [%{"name" => "todo"}],
        "assignee" => %{"login" => "testuser"},
        "created_at" => "2026-01-15T10:00:00Z",
        "updated_at" => "2026-01-16T12:00:00Z"
      },
      overrides
    )
  end

  describe "normalize_issue/2" do
    test "normalizes a GitHub issue to Linear.Issue struct" do
      gh_issue = sample_github_issue()
      result = Client.normalize_issue(gh_issue, "")

      assert %Issue{} = result
      assert result.id == "42"
      assert result.identifier == "#42"
      assert result.title == "Fix the widget"
      assert result.description == "The widget is broken"
      assert result.state == "Todo"
      assert result.branch_name == "issue-42"
      assert result.url == "https://github.com/owner/repo/issues/42"
      assert result.assignee_id == "testuser"
      assert result.labels == ["todo"]
      assert result.priority == nil
      assert result.blocked_by == []
    end

    test "derives In Progress state from label" do
      gh_issue = sample_github_issue(%{"labels" => [%{"name" => "in-progress"}]})
      result = Client.normalize_issue(gh_issue, "")
      assert result.state == "In Progress"
    end

    test "derives Human Review state from label" do
      gh_issue = sample_github_issue(%{"labels" => [%{"name" => "human-review"}]})
      result = Client.normalize_issue(gh_issue, "")
      assert result.state == "Human Review"
    end

    test "derives Done state from closed issue" do
      gh_issue = sample_github_issue(%{"state" => "closed", "labels" => []})
      result = Client.normalize_issue(gh_issue, "")
      assert result.state == "Done"
    end

    test "defaults to Todo when no state label present" do
      gh_issue = sample_github_issue(%{"labels" => [%{"name" => "bug"}]})
      result = Client.normalize_issue(gh_issue, "")
      assert result.state == "Todo"
    end

    test "handles labels_prefix" do
      gh_issue = sample_github_issue(%{"labels" => [%{"name" => "opal:in-progress"}]})
      result = Client.normalize_issue(gh_issue, "opal:")
      assert result.state == "In Progress"
    end

    test "handles nil assignee" do
      gh_issue = sample_github_issue(%{"assignee" => nil})
      result = Client.normalize_issue(gh_issue, "")
      assert result.assignee_id == nil
    end

    test "handles nil body" do
      gh_issue = sample_github_issue(%{"body" => nil})
      result = Client.normalize_issue(gh_issue, "")
      assert result.description == nil
    end

    test "parses datetime fields" do
      gh_issue = sample_github_issue()
      result = Client.normalize_issue(gh_issue, "")
      assert %DateTime{} = result.created_at
      assert result.created_at.year == 2026
      assert %DateTime{} = result.updated_at
    end
  end

  describe "state_name_to_label/2" do
    test "maps Todo to todo label" do
      assert Client.state_name_to_label("Todo", "") == "todo"
    end

    test "maps In Progress to in-progress label" do
      assert Client.state_name_to_label("In Progress", "") == "in-progress"
    end

    test "maps Human Review to human-review label" do
      assert Client.state_name_to_label("Human Review", "") == "human-review"
    end

    test "returns nil for Done" do
      assert Client.state_name_to_label("Done", "") == nil
    end

    test "returns nil for Closed" do
      assert Client.state_name_to_label("Closed", "") == nil
    end

    test "applies labels_prefix" do
      assert Client.state_name_to_label("Todo", "opal:") == "opal:todo"
    end

    test "handles case insensitivity" do
      assert Client.state_name_to_label("TODO", "") == "todo"
      assert Client.state_name_to_label("in progress", "") == "in-progress"
    end
  end

  describe "fetch_candidate_issues/0" do
    setup context do
      with_github_config(context, tracker_kind: "github")
    end

    test "returns issues from GitHub API" do
      issues = [sample_github_issue()]

      # active_states ["Todo", "In Progress"] → 2 label queries (union)
      stub_request([
        {:ok, %{status: 200, body: issues, headers: []}},
        {:ok, %{status: 200, body: [], headers: []}}
      ])

      assert {:ok, [%Issue{id: "42", title: "Fix the widget"}]} =
               Client.fetch_candidate_issues()

      assert_received {:github_api_call, :get, path, nil}
      assert path =~ "/repos/"
      assert path =~ "state=open"
    end

    test "returns error when api_key is nil" do
      workflow_file = Path.join(System.tmp_dir!(), "WORKFLOW-#{System.unique_integer([:positive])}.md")

      write_workflow_file!(workflow_file,
        tracker_kind: "github",
        tracker_api_token: nil,
        tracker_project_slug: nil,
        tracker_repo: "owner/repo"
      )

      SymphonyElixir.Workflow.set_workflow_file_path(workflow_file)
      if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()

      assert {:error, :missing_github_api_token} = Client.fetch_candidate_issues()

      File.rm(workflow_file)
    end

    test "filters out pull requests" do
      issues = [
        sample_github_issue(),
        sample_github_issue(%{"number" => 43, "pull_request" => %{"url" => "..."}})
      ]

      # active_states ["Todo", "In Progress"] → 2 label queries (union)
      stub_request([
        {:ok, %{status: 200, body: issues, headers: []}},
        {:ok, %{status: 200, body: [], headers: []}}
      ])

      assert {:ok, [%Issue{id: "42"}]} = Client.fetch_candidate_issues()
    end
  end

  describe "fetch_issues_by_states/1" do
    setup context do
      with_github_config(context, tracker_kind: "github")
    end

    test "returns empty list for empty states" do
      assert {:ok, []} = Client.fetch_issues_by_states([])
    end

    test "fetches issues matching state labels" do
      stub_request([
        {:ok, %{status: 200, body: [sample_github_issue()], headers: []}}
      ])

      assert {:ok, [%Issue{id: "42"}]} = Client.fetch_issues_by_states(["Todo"])
    end
  end

  describe "fetch_issue_states_by_ids/1" do
    setup context do
      with_github_config(context, tracker_kind: "github")
    end

    test "returns empty list for empty ids" do
      assert {:ok, []} = Client.fetch_issue_states_by_ids([])
    end

    test "fetches individual issues by number" do
      stub_request([
        {:ok, %{status: 200, body: sample_github_issue(), headers: []}}
      ])

      assert {:ok, [%Issue{id: "42"}]} = Client.fetch_issue_states_by_ids(["42"])

      assert_received {:github_api_call, :get, path, nil}
      assert path =~ "/issues/42"
    end

    test "skips 404 issues" do
      stub_request([
        {:ok, %{status: 404, body: %{"message" => "Not Found"}, headers: []}}
      ])

      assert {:ok, []} = Client.fetch_issue_states_by_ids(["999"])
    end
  end

  describe "create_comment/2" do
    setup context do
      with_github_config(context, tracker_kind: "github")
    end

    test "posts a comment" do
      stub_request([
        {:ok, %{status: 201, body: %{"id" => 1}, headers: []}}
      ])

      assert :ok = Client.create_comment("42", "Hello world")

      assert_received {:github_api_call, :post, path, %{body: "Hello world"}}
      assert path =~ "/issues/42/comments"
    end

    test "returns error on failure" do
      stub_request([
        {:ok, %{status: 403, body: %{"message" => "Forbidden"}, headers: []}}
      ])

      assert {:error, {:github_api_status, 403}} = Client.create_comment("42", "Hello")
    end
  end

  describe "add_labels/2" do
    setup context do
      with_github_config(context, tracker_kind: "github")
    end

    test "adds labels to an issue" do
      stub_request([
        {:ok, %{status: 200, body: [], headers: []}}
      ])

      assert :ok = Client.add_labels("42", ["todo"])

      assert_received {:github_api_call, :post, path, %{labels: ["todo"]}}
      assert path =~ "/issues/42/labels"
    end
  end

  describe "remove_label/2" do
    setup context do
      with_github_config(context, tracker_kind: "github")
    end

    test "removes a label from an issue" do
      stub_request([
        {:ok, %{status: 200, body: [], headers: []}}
      ])

      assert :ok = Client.remove_label("42", "todo")

      assert_received {:github_api_call, :delete, path, nil}
      assert path =~ "/issues/42/labels/todo"
    end

    test "treats 404 as success (label already removed)" do
      stub_request([
        {:ok, %{status: 404, body: %{}, headers: []}}
      ])

      assert :ok = Client.remove_label("42", "todo")
    end
  end

  describe "update_issue/2" do
    setup context do
      with_github_config(context, tracker_kind: "github")
    end

    test "patches an issue" do
      stub_request([
        {:ok, %{status: 200, body: %{}, headers: []}}
      ])

      assert :ok = Client.update_issue("42", %{state: "closed"})

      assert_received {:github_api_call, :patch, path, %{state: "closed"}}
      assert path =~ "/issues/42"
    end
  end
end
