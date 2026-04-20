defmodule SymphonyElixir.WikiTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Wiki
  alias SymphonyElixir.Wiki.Entry

  setup do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "opal-wiki-api-#{System.unique_integer([:positive])}"
      )

    knowledge_root = Path.join(test_root, "knowledge")
    File.mkdir_p!(knowledge_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "apexphere/opal-wiki-test",
      knowledge_root: knowledge_root
    )

    on_exit(fn -> File.rm_rf(test_root) end)

    %{knowledge_root: knowledge_root, project_key: "github_apexphere_opal-wiki-test"}
  end

  defp build_entry(slug, opts \\ []) do
    %Entry{
      slug: slug,
      title: Keyword.get(opts, :title, "Title for #{slug}"),
      topic: Keyword.get(opts, :topic, "topic"),
      revision: Keyword.get(opts, :revision, 1),
      created_at: "2026-04-20T00:00:00Z",
      updated_at: "2026-04-20T00:00:00Z",
      body: Keyword.get(opts, :body, "# Heading\n\nbody for #{slug}\n")
    }
  end

  describe "put/3 + list_summaries/1" do
    test "writes an entry and lists its summary", ctx do
      assert :ok = Wiki.put(ctx.project_key, build_entry("first-entry"))

      assert {:ok, [summary]} = Wiki.list_summaries(ctx.project_key)
      assert summary.slug == "first-entry"
      assert summary.title == "Title for first-entry"
      assert summary.one_line == "Heading"
    end

    test "list_summaries is empty for a fresh project", ctx do
      assert {:ok, []} = Wiki.list_summaries(ctx.project_key)
    end
  end

  describe "get/2 + exists?/2" do
    test "round-trips an entry", ctx do
      :ok = Wiki.put(ctx.project_key, build_entry("alpha"))

      assert Wiki.exists?(ctx.project_key, "alpha")
      assert {:ok, %Entry{slug: "alpha"}} = Wiki.get(ctx.project_key, "alpha")
    end

    test "exists?/2 is false for missing slug", ctx do
      refute Wiki.exists?(ctx.project_key, "ghost")
    end
  end

  describe "query/3 — fallback when no query module is configured" do
    test "returns up to :limit slugs when no LLM query module is set", ctx do
      Enum.each(1..7, fn i ->
        :ok = Wiki.put(ctx.project_key, build_entry("entry-#{i}"))
      end)

      assert {:ok, slugs} = Wiki.query(ctx.project_key, %{title: "x", body: "y"}, limit: 3)
      assert length(slugs) == 3
      assert Enum.all?(slugs, &String.starts_with?(&1, "entry-"))
    end
  end

  describe "query/3 — delegates to configured module" do
    defmodule FakeQuery do
      def query(_project_key, _ctx, _opts), do: {:ok, ["fake-1", "fake-2"]}
    end

    test "returns whatever the configured module returns", ctx do
      Application.put_env(:symphony_elixir, :wiki_query_module, FakeQuery)

      try do
        assert {:ok, ["fake-1", "fake-2"]} = Wiki.query(ctx.project_key, %{})
      after
        Application.delete_env(:symphony_elixir, :wiki_query_module)
      end
    end
  end

  describe "root!/0" do
    test "returns the configured knowledge root", ctx do
      assert Wiki.root!() == ctx.knowledge_root
    end
  end

  describe "list_summaries/1 — corrupt entries" do
    test "silently drops slugs whose on-disk body fails to parse", ctx do
      :ok = Wiki.put(ctx.project_key, build_entry("good"))

      # Write a malformed entry file alongside the good one. list_slugs
      # picks it up, but Entry.parse fails, so summary_for returns nil and
      # the slug is dropped from summaries.
      corrupt_path =
        Path.join([
          ctx.knowledge_root,
          ctx.project_key,
          "wiki",
          "corrupt.md"
        ])

      File.write!(corrupt_path, "no frontmatter here\n")

      assert {:ok, summaries} = Wiki.list_summaries(ctx.project_key)
      assert Enum.map(summaries, & &1.slug) == ["good"]
    end
  end
end
