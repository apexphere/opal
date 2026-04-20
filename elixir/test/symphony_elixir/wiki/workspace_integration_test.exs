defmodule SymphonyElixir.Wiki.WorkspaceIntegrationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Wiki
  alias SymphonyElixir.Wiki.Entry

  defmodule StubQuery do
    @moduledoc false
    def query(_project_key, _ctx, _opts), do: {:ok, ["seeded-entry"]}
  end

  setup do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "opal-wiki-ws-integ-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    knowledge_root = Path.join(test_root, "knowledge")
    File.mkdir_p!(workspace_root)
    File.mkdir_p!(knowledge_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      tracker_kind: "github",
      tracker_repo: "apexphere/opal-ws-integ",
      knowledge_root: knowledge_root
    )

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :wiki_query_module)
      File.rm_rf(test_root)
    end)

    %{test_root: test_root, project_key: "github_apexphere_opal-ws-integ"}
  end

  test "Workspace.create_for_issue injects the queried wiki entries", ctx do
    entry = %Entry{
      slug: "seeded-entry",
      title: "Seeded Entry",
      topic: "topic",
      revision: 1,
      created_at: "2026-04-19T00:00:00Z",
      updated_at: "2026-04-19T00:00:00Z",
      body: "# Seeded\n\nbody\n"
    }

    :ok = Wiki.put(ctx.project_key, entry)
    Application.put_env(:symphony_elixir, :wiki_query_module, StubQuery)

    assert {:ok, workspace} = Workspace.create_for_issue("WIKI-1")

    injected_path = Path.join(workspace, ".claude/wiki/seeded-entry.md")
    assert File.exists?(injected_path)
    assert File.read!(injected_path) =~ "Seeded"
  end

  test "Workspace.create_for_issue is a no-op on wiki when project has no entries", _ctx do
    assert {:ok, workspace} = Workspace.create_for_issue("EMPTY-WIKI")

    refute File.exists?(Path.join(workspace, ".claude/wiki/seeded-entry.md"))
  end
end
