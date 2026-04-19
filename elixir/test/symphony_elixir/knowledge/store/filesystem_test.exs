defmodule SymphonyElixir.Knowledge.Store.FilesystemTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Knowledge.Store.Filesystem

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "opal-knowledge-fs-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  describe "list_projects/1" do
    test "returns empty list when root has no projects", %{root: root} do
      assert {:ok, []} = Filesystem.list_projects(root)
    end

    test "returns project slugs sorted", %{root: root} do
      File.mkdir_p!(Path.join(root, "apexphere_opal"))
      File.mkdir_p!(Path.join(root, "apexphere_tradingagentharness"))

      assert {:ok, ["apexphere_opal", "apexphere_tradingagentharness"]} =
               Filesystem.list_projects(root)
    end

    test "returns empty list when root does not exist yet" do
      missing = Path.join(System.tmp_dir!(), "opal-knowledge-missing-#{System.unique_integer([:positive])}")

      assert {:ok, []} = Filesystem.list_projects(missing)
    end
  end

  describe "load/2" do
    test "returns empty tree for unknown project (auto-create contract)", %{root: root} do
      assert {:ok, %{files: %{}}} = Filesystem.load(root, "apexphere_tradingagentharness")
    end

    test "returns files map with relative paths to contents", %{root: root} do
      project_dir = Path.join(root, "apexphere_opal")
      File.mkdir_p!(Path.join(project_dir, "memory"))
      File.mkdir_p!(Path.join(project_dir, "skills/commit"))
      File.write!(Path.join(project_dir, "CLAUDE.md"), "# Opal knowledge\n")
      File.write!(Path.join(project_dir, "memory/MEMORY.md"), "- [note](note.md)\n")
      File.write!(Path.join(project_dir, "skills/commit/SKILL.md"), "---\nname: commit\n---\n")

      assert {:ok, %{files: files}} = Filesystem.load(root, "apexphere_opal")

      assert files["CLAUDE.md"] == "# Opal knowledge\n"
      assert files["memory/MEMORY.md"] == "- [note](note.md)\n"
      assert files["skills/commit/SKILL.md"] == "---\nname: commit\n---\n"
    end
  end

  describe "write/4" do
    test "creates parent directories and writes file", %{root: root} do
      assert :ok =
               Filesystem.write(root, "apexphere_opal", "memory/new.md", "body\n")

      assert File.read!(Path.join([root, "apexphere_opal", "memory", "new.md"])) ==
               "body\n"
    end

    test "rejects relative path that escapes project dir", %{root: root} do
      assert {:error, {:unsafe_relative_path, "../escape.md"}} =
               Filesystem.write(root, "apexphere_opal", "../escape.md", "nope")
    end

    test "rejects absolute relative_path", %{root: root} do
      assert {:error, {:unsafe_relative_path, "/etc/passwd"}} =
               Filesystem.write(root, "apexphere_opal", "/etc/passwd", "nope")
    end

    test "overwrites existing file (idempotent)", %{root: root} do
      :ok = Filesystem.write(root, "apexphere_opal", "CLAUDE.md", "v1")
      :ok = Filesystem.write(root, "apexphere_opal", "CLAUDE.md", "v2")

      assert File.read!(Path.join([root, "apexphere_opal", "CLAUDE.md"])) == "v2"
    end
  end
end
