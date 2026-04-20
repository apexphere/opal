defmodule SymphonyElixir.Wiki.InjectorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Wiki
  alias SymphonyElixir.Wiki.{Entry, Injector}

  setup do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "opal-wiki-inject-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(test_root, "workspace")
    knowledge_root = Path.join(test_root, "knowledge")
    File.mkdir_p!(workspace)
    File.mkdir_p!(knowledge_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "apexphere/opal-inject-test",
      knowledge_root: knowledge_root
    )

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :wiki_query_module)
      File.rm_rf(test_root)
    end)

    %{
      test_root: test_root,
      workspace: workspace,
      knowledge_root: knowledge_root,
      project_key: "github_apexphere_opal-inject-test"
    }
  end

  defp seed_entry(project_key, slug, body \\ nil) do
    body = body || "# #{slug}\n\nbody for #{slug}\n"

    entry = %Entry{
      slug: slug,
      title: "Title for #{slug}",
      topic: "topic",
      revision: 1,
      created_at: "2026-04-19T00:00:00Z",
      updated_at: "2026-04-19T00:00:00Z",
      body: body
    }

    :ok = Wiki.put(project_key, entry)
  end

  describe "inject/3 — happy path" do
    defmodule TopKQuery do
      def query(_project_key, _ctx, _opts), do: {:ok, ["alpha", "beta"]}
    end

    test "copies the queried entries to .claude/wiki/<slug>.md", ctx do
      seed_entry(ctx.project_key, "alpha")
      seed_entry(ctx.project_key, "beta")
      seed_entry(ctx.project_key, "gamma")

      Application.put_env(:symphony_elixir, :wiki_query_module, TopKQuery)

      assert :ok = Injector.inject(ctx.workspace, ctx.project_key, %{title: "x", body: "y"})

      assert File.read!(Path.join(ctx.workspace, ".claude/wiki/alpha.md")) =~ "alpha"
      assert File.read!(Path.join(ctx.workspace, ".claude/wiki/beta.md")) =~ "beta"
      refute File.exists?(Path.join(ctx.workspace, ".claude/wiki/gamma.md"))
    end
  end

  describe "inject/3 — query failure path" do
    defmodule FailingQuery do
      def query(_project_key, _ctx, _opts), do: {:error, :boom}
    end

    test "returns :ok and writes nothing when the query module errors", ctx do
      seed_entry(ctx.project_key, "alpha")
      Application.put_env(:symphony_elixir, :wiki_query_module, FailingQuery)

      assert :ok = Injector.inject(ctx.workspace, ctx.project_key, %{title: "x"})

      refute File.exists?(Path.join(ctx.workspace, ".claude/wiki/alpha.md"))
    end
  end

  describe "inject/3 — query raise path" do
    defmodule RaisingQuery do
      def query(_project_key, _ctx, _opts), do: raise("boom")
    end

    test "returns :ok and logs when the query module raises", ctx do
      Application.put_env(:symphony_elixir, :wiki_query_module, RaisingQuery)

      log =
        capture_log(fn ->
          assert :ok = Injector.inject(ctx.workspace, ctx.project_key, %{})
        end)

      assert log =~ "Wiki injection raised"
    end
  end

  describe "inject/3 — 20KB cap" do
    defmodule HugeQuery do
      def query(_project_key, _ctx, _opts), do: {:ok, ["big-1", "big-2", "big-3"]}
    end

    test "drops entries beyond the byte cap, keeping highest-priority slugs", ctx do
      large_body = String.duplicate("x", 8 * 1024)
      Enum.each(["big-1", "big-2", "big-3"], &seed_entry(ctx.project_key, &1, large_body))

      Application.put_env(:symphony_elixir, :wiki_query_module, HugeQuery)

      assert :ok = Injector.inject(ctx.workspace, ctx.project_key, %{})

      injected =
        Path.join(ctx.workspace, ".claude/wiki")
        |> File.ls!()
        |> Enum.sort()

      # First two should fit (each ~8KB plus frontmatter), third should NOT
      assert "big-1.md" in injected
      assert "big-2.md" in injected
      refute "big-3.md" in injected
    end
  end

  describe "inject/3 — fallback (no query module)" do
    test "uses default Wiki.query/3 fallback", ctx do
      seed_entry(ctx.project_key, "alpha")

      assert :ok = Injector.inject(ctx.workspace, ctx.project_key, %{})

      assert File.exists?(Path.join(ctx.workspace, ".claude/wiki/alpha.md"))
    end
  end

  describe "inject/3 — entry file unreadable" do
    defmodule GhostQuery do
      def query(_project_key, _ctx, _opts), do: {:ok, ["ghost", "real"]}
    end

    test "skips slugs whose entry file cannot be read", ctx do
      # "ghost" is returned by the query but never written to disk — the
      # injector must skip it and still copy the other slug.
      seed_entry(ctx.project_key, "real")
      Application.put_env(:symphony_elixir, :wiki_query_module, GhostQuery)

      assert :ok = Injector.inject(ctx.workspace, ctx.project_key, %{})

      refute File.exists?(Path.join(ctx.workspace, ".claude/wiki/ghost.md"))
      assert File.exists?(Path.join(ctx.workspace, ".claude/wiki/real.md"))
    end
  end

  describe "injected_subdir/0" do
    test "is .claude/wiki" do
      assert Injector.injected_subdir() == ".claude/wiki"
    end
  end
end
