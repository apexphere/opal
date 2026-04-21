defmodule SymphonyElixir.CuratorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Curator
  alias SymphonyElixir.Curator.{Critics, Distillers, Proposal}
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
    Application.put_env(:symphony_elixir, :curator_critic_module, Critics.Stub)
    Application.put_env(:symphony_elixir, :curator_stub_critic, :approve)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :curator_distiller_module)
      Application.delete_env(:symphony_elixir, :curator_critic_module)
      Application.delete_env(:symphony_elixir, :curator_stub_response)
      Application.delete_env(:symphony_elixir, :curator_stub_critic)
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

    test "learn/1 raises without a project_key", ctx do
      assert_raise KeyError, fn -> Curator.learn(ctx.article_path) end
    end
  end

  describe "learn/2 — summary cap" do
    test "filters by topic-overlap when there are more than 200 summaries", ctx do
      # Seed 201 entries so maybe_filter_summaries takes the over-cap branch.
      # One entry is crafted to overlap the article body (which mentions
      # "react hooks") so it survives the top-N slice.
      seed_entry(ctx.project_key, "react-hooks-overlap", title: "React hooks", topic: "react")

      Enum.each(1..200, fn i ->
        seed_entry(ctx.project_key, "filler-#{i}", title: "Filler #{i}", topic: "other")
      end)

      test_pid = self()

      Application.put_env(
        :symphony_elixir,
        :curator_stub_response,
        {:fn,
         fn _input, summaries, _candidates ->
           send(test_pid, {:summaries_count, length(summaries)})
           {:ok, Proposal.reject("test")}
         end}
      )

      assert {:ok, _} = Curator.learn(ctx.article_path, project_key: ctx.project_key)
      assert_received {:summaries_count, count}
      assert count == 200
    end
  end

  describe "learn/2 — distiller injection point" do
    test "calls the distiller with input + summaries + candidates", ctx do
      seed_entry(ctx.project_key, "alpha", title: "Alpha")
      test_pid = self()

      Application.put_env(
        :symphony_elixir,
        :curator_stub_response,
        {:fn,
         fn input, summaries, candidates ->
           send(test_pid, {:distill_called, input, summaries, candidates})
           {:ok, Proposal.reject("test")}
         end}
      )

      assert {:ok, _} = Curator.learn(ctx.article_path, project_key: ctx.project_key)

      assert_received {:distill_called, input, summaries, _candidates}
      assert is_binary(input.body)
      assert Enum.any?(summaries, &(&1.slug == "alpha"))
    end
  end

  describe "learn/2 — project context threading" do
    test "threads :project_key and :project_description into the distiller input", ctx do
      test_pid = self()

      Application.put_env(
        :symphony_elixir,
        :curator_stub_response,
        {:fn,
         fn input, _summaries, _candidates ->
           send(test_pid, {:saw_input, input})
           {:ok, Proposal.reject("test")}
         end}
      )

      assert {:ok, _} =
               Curator.learn(ctx.article_path,
                 project_key: ctx.project_key,
                 project_description: "Stock and crypto technical analysis"
               )

      assert_received {:saw_input, input}
      assert input.project_key == ctx.project_key
      assert input.project_description == "Stock and crypto technical analysis"
    end

    test "threads the same context into the critic", ctx do
      test_pid = self()

      Application.put_env(:symphony_elixir, :curator_stub_response, {:reject, "noop"})

      Application.put_env(
        :symphony_elixir,
        :curator_stub_critic,
        {:fn,
         fn _body, _summaries, _candidates, context ->
           send(test_pid, {:saw_critic_context, context})
           {:ok, :approve}
         end}
      )

      assert {:ok, _} =
               Curator.learn(ctx.article_path,
                 project_key: ctx.project_key,
                 project_description: "Stock and crypto technical analysis"
               )

      assert_received {:saw_critic_context, context}
      assert context.project_key == ctx.project_key
      assert context.project_description == "Stock and crypto technical analysis"
    end

    test "falls back to Knowledge.project_description/0 when no opt is given", ctx do
      Application.put_env(
        :symphony_elixir,
        :curator_project_description,
        "Domain from config"
      )

      test_pid = self()

      Application.put_env(
        :symphony_elixir,
        :curator_stub_response,
        {:fn,
         fn input, _summaries, _candidates ->
           send(test_pid, {:saw_input, input})
           {:ok, Proposal.reject("test")}
         end}
      )

      try do
        assert {:ok, _} = Curator.learn(ctx.article_path, project_key: ctx.project_key)
        assert_received {:saw_input, input}
        assert input.project_description == "Domain from config"
      after
        Application.delete_env(:symphony_elixir, :curator_project_description)
      end
    end

    test "project_description is nil when neither opt nor config is set", ctx do
      Application.delete_env(:symphony_elixir, :curator_project_description)
      test_pid = self()

      Application.put_env(
        :symphony_elixir,
        :curator_stub_response,
        {:fn,
         fn input, _summaries, _candidates ->
           send(test_pid, {:saw_input, input})
           {:ok, Proposal.reject("test")}
         end}
      )

      assert {:ok, _} = Curator.learn(ctx.article_path, project_key: ctx.project_key)
      assert_received {:saw_input, input}
      assert input.project_description == nil
    end
  end

  defp failure_payload(overrides \\ %{}) do
    Map.merge(
      %{
        recipe: %SymphonyElixir.Verification.Recipe{
          description: "run the suite",
          steps: []
        },
        failed_step: %{name: "ping", shell: "curl -fsS http://localhost:4000"},
        output: "connection refused\nsocket error",
        issue_ref: "issue-123",
        started_at: "2026-04-20T12:00:00Z"
      },
      overrides
    )
  end

  describe "learn_from_failure/2 — distills a failed verify step" do
    setup do
      Application.put_env(
        :symphony_elixir,
        :curator_failure_distiller_module,
        Distillers.Stub
      )

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :curator_failure_distiller_module)
      end)

      :ok
    end

    test "creates a lesson entry with kind=verify_log", ctx do
      Application.put_env(
        :symphony_elixir,
        :curator_stub_response,
        {:create,
         %{
           "slug" => "curl-failure-lesson",
           "title" => "Curl failure lesson",
           "topic" => "infra",
           "body" => "# lesson\n\ncheck the server is running\n"
         }}
      )

      now_fixed = "2026-04-20T12:00:00Z"

      assert {:ok, proposal} =
               Curator.learn_from_failure(failure_payload(),
                 project_key: ctx.project_key,
                 now: fn -> now_fixed end
               )

      assert {:create, "curl-failure-lesson", entry} = proposal.decision

      assert [%{kind: "verify_log", ref: source_ref, ingested_at: ^now_fixed}] = entry.sources
      assert source_ref =~ "issue-123"
      assert source_ref =~ "#step:ping"
      assert source_ref =~ "@run the suite"
    end

    test "truncates very large outputs head+tail", ctx do
      huge = String.duplicate("x", Curator.max_article_bytes())
      test_pid = self()

      Application.put_env(
        :symphony_elixir,
        :curator_stub_response,
        {:fn,
         fn input, _summaries, _candidates ->
           send(test_pid, {:body_size, byte_size(input.body)})
           {:ok, Proposal.reject("test")}
         end}
      )

      assert {:ok, _} =
               Curator.learn_from_failure(
                 failure_payload(%{output: huge}),
                 project_key: ctx.project_key
               )

      assert_received {:body_size, size}
      assert size < Curator.max_article_bytes()
    end

    test "surfaces a distiller error", ctx do
      Application.delete_env(:symphony_elixir, :curator_stub_response)

      assert {:error, :stub_response_not_configured} =
               Curator.learn_from_failure(failure_payload(), project_key: ctx.project_key)
    end

    test "passes refine proposals through when target exists", ctx do
      seed_entry(ctx.project_key, "flaky-endpoints", title: "Flaky endpoints")

      Application.put_env(
        :symphony_elixir,
        :curator_stub_response,
        {:refine, "flaky-endpoints", "merged lesson body\n"}
      )

      assert {:ok, proposal} =
               Curator.learn_from_failure(failure_payload(), project_key: ctx.project_key)

      assert {:refine, "flaky-endpoints", _} = proposal.decision
    end

    test "tolerates step maps with string keys", ctx do
      Application.put_env(:symphony_elixir, :curator_stub_response, {:reject, "noop"})

      payload =
        failure_payload(%{failed_step: %{"name" => "ping", "shell" => "curl -fsS ..."}})

      assert {:ok, %Proposal{decision: :reject}} =
               Curator.learn_from_failure(payload, project_key: ctx.project_key)
    end

    test "tolerates recipes without a description", ctx do
      Application.put_env(:symphony_elixir, :curator_stub_response, {:reject, "noop"})

      payload =
        failure_payload(%{
          recipe: %SymphonyElixir.Verification.Recipe{description: nil, steps: []}
        })

      assert {:ok, _} = Curator.learn_from_failure(payload, project_key: ctx.project_key)
    end

    test "stamps started_at with a default when caller omits it", ctx do
      Application.put_env(:symphony_elixir, :curator_stub_response, {:reject, "noop"})

      payload =
        failure_payload()
        |> Map.delete(:started_at)

      assert {:ok, _} = Curator.learn_from_failure(payload, project_key: ctx.project_key)
    end
  end

  describe "truncate_head_tail/2" do
    test "leaves short strings intact" do
      assert SymphonyElixir.Curator.truncate_head_tail("hello", 10) == "hello"
    end

    test "head+tail truncates strings over 2*half_bytes" do
      text = String.duplicate("a", 100) <> String.duplicate("b", 100)
      result = SymphonyElixir.Curator.truncate_head_tail(text, 10)
      assert result =~ "[truncated]"
      assert String.starts_with?(result, "aaaa")
      assert String.ends_with?(result, "bbbb")
    end
  end

  describe "learn/2 — critic fan-out" do
    test "critic :approve passes producer create through", ctx do
      Application.put_env(
        :symphony_elixir,
        :curator_stub_response,
        {:create, %{"slug" => "beta", "title" => "B", "topic" => "t", "body" => "body"}}
      )

      Application.put_env(:symphony_elixir, :curator_stub_critic, :approve)

      assert {:ok, proposal} = Curator.learn(ctx.article_path, project_key: ctx.project_key)
      assert {:create, "beta", _entry} = proposal.decision
      assert proposal.critic_verdict == :approve
    end

    test "critic :reject overrides producer create", ctx do
      Application.put_env(
        :symphony_elixir,
        :curator_stub_response,
        {:create, %{"slug" => "beta", "title" => "B", "topic" => "t", "body" => "body"}}
      )

      Application.put_env(:symphony_elixir, :curator_stub_critic, {:reject, "one-off"})

      assert {:ok, proposal} = Curator.learn(ctx.article_path, project_key: ctx.project_key)
      assert proposal.decision == :reject
      assert {:create, "beta", _} = proposal.producer_decision
      assert proposal.rationale == "critic rejected: one-off"
    end

    test "critic :conflict on producer create routes to :human_review", ctx do
      seed_entry(ctx.project_key, "alpha", title: "Alpha")

      Application.put_env(
        :symphony_elixir,
        :curator_stub_response,
        {:create, %{"slug" => "beta", "title" => "B", "topic" => "t", "body" => "body"}}
      )

      Application.put_env(
        :symphony_elixir,
        :curator_stub_critic,
        {:conflict, "alpha", "contradicts alpha"}
      )

      assert {:ok, proposal} = Curator.learn(ctx.article_path, project_key: ctx.project_key)

      assert {:human_review, {:create, "beta", _}, {:conflict, "alpha", "contradicts alpha"}} =
               proposal.decision
    end

    test "critic :conflict on producer refine routes to :human_review", ctx do
      seed_entry(ctx.project_key, "auth-tokens", title: "Auth tokens")
      seed_entry(ctx.project_key, "other-slug", title: "Other")

      Application.put_env(:symphony_elixir, :curator_stub_response, {:refine, "auth-tokens", "merged"})

      Application.put_env(
        :symphony_elixir,
        :curator_stub_critic,
        {:conflict, "other-slug", "contradicts other"}
      )

      assert {:ok, proposal} = Curator.learn(ctx.article_path, project_key: ctx.project_key)

      assert {:human_review, {:refine, "auth-tokens", "merged"}, {:conflict, "other-slug", "contradicts other"}} = proposal.decision
    end

    test "surfaces critic errors", ctx do
      Application.put_env(:symphony_elixir, :curator_stub_response, {:reject, "x"})
      Application.delete_env(:symphony_elixir, :curator_stub_critic)

      assert {:error, :stub_critic_not_configured} =
               Curator.learn(ctx.article_path, project_key: ctx.project_key)
    end

    test "surfaces distiller errors even when critic succeeds", ctx do
      Application.delete_env(:symphony_elixir, :curator_stub_response)
      Application.put_env(:symphony_elixir, :curator_stub_critic, :approve)

      assert {:error, :stub_response_not_configured} =
               Curator.learn(ctx.article_path, project_key: ctx.project_key)
    end
  end

  describe "resolve_critic/1" do
    test ":claude resolves to Consistency" do
      assert Curator.resolve_critic(:claude) == Critics.Consistency
    end

    test ":codex resolves to Codex" do
      assert Curator.resolve_critic(:codex) == Critics.Codex
    end

    test "a module reference passes through" do
      assert Curator.resolve_critic(Critics.Stub) == Critics.Stub
    end

    test "unknown module reference raises with a helpful message" do
      assert_raise ArgumentError, ~r/unknown critic runtime/, fn ->
        Curator.resolve_critic(:DefinitelyNotAModule)
      end
    end
  end

  describe "default_critic dispatcher" do
    test "treats a configured :codex atom as Critics.Codex", ctx do
      Application.put_env(:symphony_elixir, :curator_critic_module, :codex)

      # Ask for a verdict via Codex, but with a bogus binary so the call
      # fails fast — we only care that dispatch picked Codex rather than
      # Consistency.
      Application.put_env(
        :symphony_elixir,
        :curator_codex_command,
        "definitely-not-a-real-cmd-xyzzy"
      )

      Application.put_env(:symphony_elixir, :curator_stub_response, {:reject, "x"})

      try do
        assert {:error, {:codex_command_not_found, _}} =
                 Curator.learn(ctx.article_path, project_key: ctx.project_key)
      after
        Application.put_env(:symphony_elixir, :curator_critic_module, Critics.Stub)
        Application.delete_env(:symphony_elixir, :curator_codex_command)
      end
    end
  end
end
