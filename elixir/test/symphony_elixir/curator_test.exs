defmodule SymphonyElixir.CuratorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Curator
  alias SymphonyElixir.Curator.{Distillers, Proposal}
  alias SymphonyElixir.Wiki
  alias SymphonyElixir.Wiki.Entry

  setup do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "opal-curator-#{System.unique_integer([:positive])}"
      )

    knowledge_root = Path.join(test_root, "knowledge")
    File.mkdir_p!(knowledge_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "apexphere/opal-curator-test",
      knowledge_root: knowledge_root
    )

    Application.put_env(:symphony_elixir, :curator_distiller_module, Distillers.Stub)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :curator_distiller_module)
      Application.delete_env(:symphony_elixir, :curator_stub_response)
      File.rm_rf(test_root)
    end)

    article_path = Path.join(test_root, "article.md")
    File.write!(article_path, "# An article\n\nbody about react hooks\n")

    %{
      test_root: test_root,
      knowledge_root: knowledge_root,
      project_key: "github_apexphere_opal-curator-test",
      article_path: article_path
    }
  end

  defp seed_entry(project_key, slug, opts \\ []) do
    entry = %Entry{
      slug: slug,
      title: Keyword.get(opts, :title, "Title for #{slug}"),
      topic: Keyword.get(opts, :topic, "topic"),
      revision: 1,
      created_at: "2026-04-19T00:00:00Z",
      updated_at: "2026-04-19T00:00:00Z",
      body: Keyword.get(opts, :body, "# #{slug}\n\nseeded body for #{slug}\n")
    }

    :ok = Wiki.put(project_key, entry)
  end

  describe "learn/2 — :reject" do
    test "passes through and never writes the wiki", ctx do
      Application.put_env(:symphony_elixir, :curator_stub_response, {:reject, "not relevant"})

      assert {:ok, %Proposal{decision: :reject, rationale: "not relevant"}} =
               Curator.learn(ctx.article_path, project_key: ctx.project_key)

      assert {:ok, []} = Wiki.list_summaries(ctx.project_key)
    end
  end

  describe "learn/2 — :create" do
    test "sanitizes the slug and stamps timestamps + source", ctx do
      Application.put_env(
        :symphony_elixir,
        :curator_stub_response,
        {:create,
         %{
           "slug" => "React Hooks: Cleanup!",
           "title" => "useEffect cleanup",
           "topic" => "react/hooks",
           "body" => "# Cleanup\n\nbody\n"
         }}
      )

      now_fixed = "2026-04-20T12:00:00Z"

      assert {:ok, proposal} =
               Curator.learn(ctx.article_path,
                 project_key: ctx.project_key,
                 source_ref: "feeds/react.md",
                 now: fn -> now_fixed end
               )

      assert {:create, "react-hooks-cleanup", entry} = proposal.decision
      assert entry.slug == "react-hooks-cleanup"
      assert entry.created_at == now_fixed
      assert entry.updated_at == now_fixed
      assert [%{kind: "article", ref: "feeds/react.md", ingested_at: ^now_fixed}] = entry.sources
    end

    test "resolves slug collisions by appending -2", ctx do
      seed_entry(ctx.project_key, "react-hooks-cleanup")

      Application.put_env(
        :symphony_elixir,
        :curator_stub_response,
        {:create,
         %{
           "slug" => "React Hooks Cleanup",
           "title" => "Different angle",
           "topic" => "react/hooks",
           "body" => "body\n"
         }}
      )

      assert {:ok, proposal} =
               Curator.learn(ctx.article_path, project_key: ctx.project_key)

      assert {:create, "react-hooks-cleanup-2", _entry} = proposal.decision
    end
  end

  describe "learn/2 — :refine" do
    test "passes through when the input slug exists", ctx do
      seed_entry(ctx.project_key, "auth-tokens", title: "Auth tokens")

      Application.put_env(:symphony_elixir, :curator_stub_response, {:refine, "auth-tokens", "merged body\n"})

      assert {:ok, proposal} =
               Curator.learn(ctx.article_path, project_key: ctx.project_key)

      assert {:refine, "auth-tokens", "merged body\n"} = proposal.decision
    end

    test "errors when the proposed refine target does not exist", ctx do
      Application.put_env(:symphony_elixir, :curator_stub_response, {:refine, "ghost-slug", "merged"})

      assert {:error, {:refine_target_missing, "ghost-slug"}} =
               Curator.learn(ctx.article_path, project_key: ctx.project_key)
    end
  end

  describe "learn/2 — input safety" do
    test "rejects articles larger than 32KB", ctx do
      huge = String.duplicate("a", Curator.max_article_bytes() + 1)
      File.write!(ctx.article_path, huge)

      Application.put_env(:symphony_elixir, :curator_stub_response, :reject)

      assert {:error, {:article_too_large, _, _}} =
               Curator.learn(ctx.article_path, project_key: ctx.project_key)
    end
  end

  describe "learn/2 — distiller injection point" do
    defmodule InspectingDistiller do
      @moduledoc false
      @behaviour SymphonyElixir.Curator.Distiller

      alias SymphonyElixir.Curator.Proposal

      def distill(input, summaries, candidates) do
        send(self(), {:distill_called, input, summaries, candidates})
        {:ok, Proposal.reject("test")}
      end
    end

    test "calls the distiller with input + summaries + candidates", ctx do
      seed_entry(ctx.project_key, "alpha", title: "Alpha")

      assert {:ok, _} =
               Curator.learn(ctx.article_path,
                 project_key: ctx.project_key,
                 distiller: InspectingDistiller
               )

      assert_received {:distill_called, input, summaries, _candidates}
      assert is_binary(input.body)
      assert Enum.any?(summaries, &(&1.slug == "alpha"))
    end
  end
end
