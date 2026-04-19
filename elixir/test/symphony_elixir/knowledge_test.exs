defmodule SymphonyElixir.KnowledgeTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Knowledge

  describe "inject_tree/2" do
    setup do
      workspace =
        Path.join(
          System.tmp_dir!(),
          "opal-knowledge-ws-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(workspace)
      on_exit(fn -> File.rm_rf(workspace) end)
      %{workspace: workspace}
    end

    test "writes skills and memory files under .claude/", %{workspace: workspace} do
      tree = %{
        files: %{
          "CLAUDE.md" => "# Opal knowledge for apexphere/opal\n",
          "skills/commit/SKILL.md" => "---\nname: commit\n---\n",
          "memory/MEMORY.md" => "- [note](note.md)\n"
        }
      }

      assert :ok = Knowledge.inject_tree(workspace, tree)

      assert File.read!(Path.join(workspace, ".claude/opal-knowledge.md")) ==
               "# Opal knowledge for apexphere/opal\n"

      assert File.read!(Path.join(workspace, ".claude/skills/commit/SKILL.md")) ==
               "---\nname: commit\n---\n"

      assert File.read!(Path.join(workspace, ".claude/memory/MEMORY.md")) ==
               "- [note](note.md)\n"
    end

    test "creates workspace CLAUDE.md with @-import when target has none", %{workspace: workspace} do
      tree = %{files: %{"CLAUDE.md" => "body\n"}}

      :ok = Knowledge.inject_tree(workspace, tree)

      content = File.read!(Path.join(workspace, "CLAUDE.md"))
      assert content =~ "@.claude/opal-knowledge.md"
    end

    test "preserves target-repo-native CLAUDE.md and appends import if missing",
         %{workspace: workspace} do
      File.write!(Path.join(workspace, "CLAUDE.md"), "# Target project rules\n")

      :ok = Knowledge.inject_tree(workspace, %{files: %{"CLAUDE.md" => "body\n"}})

      content = File.read!(Path.join(workspace, "CLAUDE.md"))
      assert content =~ "# Target project rules"
      assert content =~ "@.claude/opal-knowledge.md"
    end

    test "is idempotent — re-run does not duplicate import line", %{workspace: workspace} do
      tree = %{files: %{"CLAUDE.md" => "body\n"}}

      :ok = Knowledge.inject_tree(workspace, tree)
      :ok = Knowledge.inject_tree(workspace, tree)

      content = File.read!(Path.join(workspace, "CLAUDE.md"))
      occurrences = Regex.scan(~r/@\.claude\/opal-knowledge\.md/, content) |> length()
      assert occurrences == 1
    end

    test "empty tree produces no-op (no CLAUDE.md, no .claude dir polluted)",
         %{workspace: workspace} do
      :ok = Knowledge.inject_tree(workspace, %{files: %{}})

      refute File.exists?(Path.join(workspace, "CLAUDE.md"))
      refute File.exists?(Path.join(workspace, ".claude/opal-knowledge.md"))
    end

    test "treats tree without CLAUDE.md as skills-only injection", %{workspace: workspace} do
      tree = %{
        files: %{
          "skills/push/SKILL.md" => "---\nname: push\n---\n"
        }
      }

      :ok = Knowledge.inject_tree(workspace, tree)

      assert File.read!(Path.join(workspace, ".claude/skills/push/SKILL.md")) =~ "name: push"
      refute File.exists?(Path.join(workspace, "CLAUDE.md"))
      refute File.exists?(Path.join(workspace, ".claude/opal-knowledge.md"))
    end
  end

  describe "project_key_for/1" do
    test "github kind returns owner_repo slug" do
      tracker = %{kind: "github", repo: "apexphere/opal", project_slug: nil}
      assert Knowledge.project_key_for(tracker) == "github_apexphere_opal"
    end

    test "linear kind returns linear_<slug>" do
      tracker = %{kind: "linear", repo: nil, project_slug: "alpha"}
      assert Knowledge.project_key_for(tracker) == "linear_alpha"
    end

    test "memory kind returns memory_<slug>" do
      tracker = %{kind: "memory", repo: nil, project_slug: "test"}
      assert Knowledge.project_key_for(tracker) == "memory_test"
    end

    test "github kind without repo returns github_unknown" do
      tracker = %{kind: "github", repo: nil, project_slug: nil}
      assert Knowledge.project_key_for(tracker) == "github_unknown"
    end

    test "sanitizes unsafe chars in slug" do
      tracker = %{kind: "github", repo: "owner/repo with spaces", project_slug: nil}
      assert Knowledge.project_key_for(tracker) == "github_owner_repo_with_spaces"
    end

    test "unrecognized kind falls back to unknown slug" do
      tracker = %{kind: "jira", repo: nil, project_slug: nil}
      assert Knowledge.project_key_for(tracker) == "jira_unknown"
    end
  end
end
