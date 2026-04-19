defmodule SymphonyElixir.KnowledgeIntegrationTest do
  use SymphonyElixir.TestSupport

  test "workspace creation injects seeded project knowledge into .claude/" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "opal-knowledge-integ-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      knowledge_root = Path.join(test_root, "knowledge")

      project_key = "github_apexphere_opal-test-tracker"
      project_dir = Path.join(knowledge_root, project_key)
      File.mkdir_p!(Path.join(project_dir, "memory"))
      File.mkdir_p!(Path.join(project_dir, "skills/summarize_run"))
      File.write!(Path.join(project_dir, "CLAUDE.md"), "# Seeded knowledge\n")
      File.write!(Path.join(project_dir, "memory/MEMORY.md"), "- [note](note.md)\n")

      File.write!(
        Path.join(project_dir, "skills/summarize_run/SKILL.md"),
        "---\nname: summarize_run\n---\n"
      )

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        tracker_kind: "github",
        tracker_repo: "apexphere/opal-test-tracker",
        knowledge_root: knowledge_root
      )

      assert {:ok, workspace} = Workspace.create_for_issue("INT-1")

      assert File.read!(Path.join(workspace, ".claude/opal-knowledge.md")) ==
               "# Seeded knowledge\n"

      assert File.read!(Path.join(workspace, ".claude/memory/MEMORY.md")) ==
               "- [note](note.md)\n"

      assert File.read!(Path.join(workspace, ".claude/skills/summarize_run/SKILL.md")) =~
               "name: summarize_run"

      claude_md = File.read!(Path.join(workspace, "CLAUDE.md"))
      assert claude_md =~ "@.claude/opal-knowledge.md"
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace creation is a no-op on knowledge when project has no seeded tree" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "opal-knowledge-integ-empty-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      knowledge_root = Path.join(test_root, "knowledge")
      File.mkdir_p!(knowledge_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        tracker_kind: "github",
        tracker_repo: "apexphere/never-seeded",
        knowledge_root: knowledge_root
      )

      assert {:ok, workspace} = Workspace.create_for_issue("EMPTY-1")

      refute File.exists?(Path.join(workspace, ".claude/opal-knowledge.md"))
      refute File.exists?(Path.join(workspace, "CLAUDE.md"))
    after
      File.rm_rf(test_root)
    end
  end

  test "Knowledge.capture/3 writes into the configured knowledge root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "opal-knowledge-capture-#{System.unique_integer([:positive])}"
      )

    try do
      knowledge_root = Path.join(test_root, "knowledge")
      File.mkdir_p!(knowledge_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "apexphere/opal-test-tracker",
        knowledge_root: knowledge_root
      )

      assert :ok =
               SymphonyElixir.Knowledge.capture(
                 "github_apexphere_opal-test-tracker",
                 "memory/new_topic.md",
                 "- captured entry\n"
               )

      assert File.read!(
               Path.join([
                 knowledge_root,
                 "github_apexphere_opal-test-tracker",
                 "memory/new_topic.md"
               ])
             ) == "- captured entry\n"
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace creation preserves target repo's native CLAUDE.md and appends import" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "opal-knowledge-integ-coexist-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      knowledge_root = Path.join(test_root, "knowledge")

      project_key = "github_apexphere_opal-test-tracker"
      project_dir = Path.join(knowledge_root, project_key)
      File.mkdir_p!(project_dir)
      File.write!(Path.join(project_dir, "CLAUDE.md"), "# Opal-authored\n")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        tracker_kind: "github",
        tracker_repo: "apexphere/opal-test-tracker",
        hook_after_create: "printf '# Target repo native\\n' > CLAUDE.md",
        knowledge_root: knowledge_root
      )

      assert {:ok, workspace} = Workspace.create_for_issue("COEX-1")

      claude_md = File.read!(Path.join(workspace, "CLAUDE.md"))
      assert claude_md =~ "# Target repo native"
      assert claude_md =~ "@.claude/opal-knowledge.md"

      assert File.read!(Path.join(workspace, ".claude/opal-knowledge.md")) =~
               "# Opal-authored"
    after
      File.rm_rf(test_root)
    end
  end
end
