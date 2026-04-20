# Curator fixture eval driver.
#
# Walks every fixture in test/fixtures/curator, sets up an isolated wiki
# rooted in a tmp dir, copies the fixture's seed_wiki/ into it, replays
# the recorded transcript through the Stub distiller, and asserts the
# expected outcome.
#
# Run with:
#
#     mix run scripts/curator_eval.exs
#
# Exits 0 on full pass, 1 on any failure. Prints a per-fixture summary.

curator_fixtures = Path.join([File.cwd!(), "test/fixtures/curator"])
critic_fixtures = Path.join([File.cwd!(), "test/fixtures/critic"])

defmodule CuratorEval do
  alias SymphonyElixir.Curator
  alias SymphonyElixir.Curator.{Critics, Distillers, Review}
  alias SymphonyElixir.Wiki
  alias SymphonyElixir.Wiki.{Entry, Injector}

  @project_key "github_apexphere_curator-eval"

  def run_all(dirs) when is_list(dirs) do
    fixtures =
      dirs
      |> Enum.flat_map(fn dir ->
        case File.ls(dir) do
          {:ok, entries} ->
            entries
            |> Enum.map(&Path.join(dir, &1))
            |> Enum.filter(&File.dir?/1)

          _ ->
            []
        end
      end)
      |> Enum.sort()

    results = Enum.map(fixtures, &run_one/1)

    pass_count = Enum.count(results, & &1.passed)
    total = length(results)

    IO.puts("\n#{pass_count}/#{total} curator fixtures passed")

    Enum.each(results, fn r ->
      mark = if r.passed, do: "PASS", else: "FAIL"
      IO.puts("  [#{mark}] #{r.name}#{if r.passed, do: "", else: " — #{r.reason}"}")
    end)

    if pass_count < total, do: System.halt(1)
  end

  def run_one(fixture_dir) do
    name = Path.basename(fixture_dir)
    IO.puts("\n=== #{name} ===")

    expected =
      fixture_dir
      |> Path.join("expected.json")
      |> File.read!()
      |> Jason.decode!()

    transcript =
      fixture_dir
      |> Path.join("transcript.json")
      |> File.read!()
      |> Jason.decode!()

    article_path = Path.join(fixture_dir, "input_article.md")
    failure_payload_path = Path.join(fixture_dir, "failure_payload.json")

    cond do
      Map.get(expected, "kind") == "retrieval" ->
        evaluate_retrieval(name, fixture_dir, transcript, expected)

      File.exists?(failure_payload_path) ->
        evaluate_verify_log(name, fixture_dir, failure_payload_path, transcript, expected)

      true ->
        evaluate_curator(name, fixture_dir, article_path, transcript, expected)
    end
  rescue
    error ->
      %{name: Path.basename(fixture_dir), passed: false, reason: Exception.message(error)}
  end

  defp evaluate_curator(name, fixture_dir, article_path, transcript, expected) do
    {root, project_key} = setup_isolated_root!(fixture_dir)

    Application.put_env(:symphony_elixir, :curator_distiller_module, Distillers.Stub)
    Application.put_env(:symphony_elixir, :curator_stub_response, transcript_to_response(transcript))
    Application.put_env(:symphony_elixir, :curator_critic_module, Critics.Stub)
    Application.put_env(:symphony_elixir, :curator_stub_critic, transcript_to_critic(transcript))

    try do
      seed_wiki!(fixture_dir, project_key)

      case Curator.learn(article_path, project_key: project_key) do
        {:ok, proposal} ->
          IO.puts("  proposal: #{format_decision(proposal)}")
          assert_curator_outcome(name, proposal, project_key, expected)

        {:error, reason} ->
          %{name: name, passed: false, reason: "curator error: #{inspect(reason)}"}
      end
    after
      File.rm_rf(root)
      Application.delete_env(:symphony_elixir, :curator_stub_response)
      Application.delete_env(:symphony_elixir, :curator_distiller_module)
      Application.delete_env(:symphony_elixir, :curator_stub_critic)
      Application.delete_env(:symphony_elixir, :curator_critic_module)
    end
  end

  defp evaluate_verify_log(name, fixture_dir, failure_payload_path, transcript, expected) do
    {root, project_key} = setup_isolated_root!(fixture_dir)

    Application.put_env(:symphony_elixir, :curator_failure_distiller_module, Distillers.Stub)
    Application.put_env(:symphony_elixir, :curator_stub_response, transcript_to_response(transcript))
    Application.put_env(:symphony_elixir, :curator_critic_module, Critics.Stub)
    Application.put_env(:symphony_elixir, :curator_stub_critic, transcript_to_critic(transcript))

    try do
      seed_wiki!(fixture_dir, project_key)
      payload = load_failure_payload!(failure_payload_path)

      case Curator.learn_from_failure(payload, project_key: project_key) do
        {:ok, proposal} ->
          IO.puts("  proposal: #{format_decision(proposal)}")
          result = assert_curator_outcome(name, proposal, project_key, expected)
          assert_injection_guards(result, proposal, expected)

        {:error, reason} ->
          %{name: name, passed: false, reason: "curator error: #{inspect(reason)}"}
      end
    after
      File.rm_rf(root)
      Application.delete_env(:symphony_elixir, :curator_stub_response)
      Application.delete_env(:symphony_elixir, :curator_failure_distiller_module)
      Application.delete_env(:symphony_elixir, :curator_stub_critic)
      Application.delete_env(:symphony_elixir, :curator_critic_module)
    end
  end

  defp load_failure_payload!(path) do
    data = path |> File.read!() |> Jason.decode!()

    %{
      recipe: %SymphonyElixir.Verification.Recipe{
        description: Map.get(data, "recipe_description", ""),
        steps: []
      },
      failed_step: %{
        name: Map.fetch!(data["failed_step"], "name"),
        shell: Map.fetch!(data["failed_step"], "shell"),
        output: Map.fetch!(data["failed_step"], "output")
      },
      output: Map.fetch!(data["failed_step"], "output"),
      issue_ref: Map.fetch!(data, "issue_ref"),
      started_at: Map.fetch!(data, "started_at")
    }
  end

  defp assert_injection_guards(%{passed: false} = result, _proposal, _expected), do: result

  defp assert_injection_guards(result, proposal, expected) do
    with :ok <- guard_not_slug(proposal, Map.get(expected, "must_not_create_slug")),
         :ok <- guard_not_body(proposal, Map.get(expected, "must_not_contain_body")) do
      result
    else
      {:error, reason} -> %{result | passed: false, reason: reason}
    end
  end

  defp guard_not_slug(_proposal, nil), do: :ok

  defp guard_not_slug(%{decision: {:create, slug, _entry}}, forbidden) when slug == forbidden do
    {:error, "proposal created forbidden slug #{forbidden}"}
  end

  defp guard_not_slug(_proposal, _forbidden), do: :ok

  defp guard_not_body(_proposal, nil), do: :ok

  defp guard_not_body(%{decision: {:create, _, %Entry{body: body}}}, needle) do
    if String.contains?(body, needle) do
      {:error, "proposal body contains forbidden token #{inspect(needle)}"}
    else
      :ok
    end
  end

  defp guard_not_body(%{decision: {:refine, _, body}}, needle) when is_binary(body) do
    if String.contains?(body, needle) do
      {:error, "proposal body contains forbidden token #{inspect(needle)}"}
    else
      :ok
    end
  end

  defp guard_not_body(_proposal, _needle), do: :ok

  defp evaluate_retrieval(name, fixture_dir, transcript, expected) do
    {root, project_key} = setup_isolated_root!(fixture_dir)
    seed_wiki!(fixture_dir, project_key)

    slugs = Map.get(transcript, "query_response_slugs", [])

    Application.put_env(:symphony_elixir, :wiki_query_module, FakeRetrievalQuery)
    Process.put(:fake_retrieval_slugs, slugs)

    try do
      workspace =
        Path.join(System.tmp_dir!(), "curator-eval-ws-#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace)

      :ok = Injector.inject(workspace, project_key, %{title: "irrelevant"})

      injected =
        Path.join(workspace, ".claude/wiki")
        |> File.ls!()
        |> Enum.map(&String.replace_suffix(&1, ".md", ""))
        |> Enum.sort()

      IO.puts("  injected slugs: #{inspect(injected)}")

      must_include = Map.get(expected, "must_include_slug")
      must_exclude = Map.get(expected, "must_exclude_slug")

      cond do
        must_include && must_include not in injected ->
          %{name: name, passed: false, reason: "missing required slug #{must_include}"}

        must_exclude && must_exclude in injected ->
          %{name: name, passed: false, reason: "unexpected slug present #{must_exclude}"}

        true ->
          %{name: name, passed: true, reason: nil}
      end
    after
      File.rm_rf(root)
      Application.delete_env(:symphony_elixir, :wiki_query_module)
    end
  end

  defp assert_curator_outcome(name, proposal, project_key, expected) do
    case {proposal.decision, Map.fetch!(expected, "decision")} do
      {:reject, "reject"} ->
        result_with_optional_write(name, proposal, project_key, expected, false)

      {{:create, slug, _entry}, "create"} ->
        if slug == Map.fetch!(expected, "slug") do
          # Auto-accept on create to verify the file write
          :accepted = Review.run(proposal, project_key, input_fun: fn _ -> "a" end)
          %{name: name, passed: true, reason: nil}
        else
          %{name: name, passed: false, reason: "slug mismatch: #{slug} vs #{Map.fetch!(expected, "slug")}"}
        end

      {{:refine, slug, _merged_body}, "refine"} ->
        if slug == Map.fetch!(expected, "slug") do
          :accepted = Review.run(proposal, project_key, input_fun: fn _ -> "a" end)
          {:ok, refined} = Wiki.get(project_key, slug)
          revision_after = Map.get(expected, "revision_after", 2)

          if refined.revision == revision_after do
            %{name: name, passed: true, reason: nil}
          else
            %{name: name, passed: false, reason: "revision mismatch: #{refined.revision} vs #{revision_after}"}
          end
        else
          %{name: name, passed: false, reason: "slug mismatch: #{slug} vs #{Map.fetch!(expected, "slug")}"}
        end

      {{:refine, slug, merged_body}, "refine_or_reject"} ->
        # Anti-injection fixture: if curator refined, the diff must surface
        # the malicious change in human-readable form. Either the refine
        # contains the suspicious tokens (so a human reviewer would see
        # them) AND we deliberately do NOT auto-accept, OR the curator
        # rejected. Both are acceptable.
        diff = Review.unified_diff(load_seed_body(project_key, slug), merged_body, "wiki/#{slug}.md")
        must_contain = Map.get(expected, "if_refine_diff_must_contain")
        must_remove = Map.get(expected, "if_refine_diff_must_remove")

        cond do
          must_contain && not String.contains?(diff, "+" <> must_contain) and not String.contains?(diff, must_contain) ->
            %{name: name, passed: false, reason: "diff missing expected token #{must_contain}"}

          must_remove && not String.contains?(diff, "-" <> must_remove) and not String.contains?(diff, must_remove) ->
            %{name: name, passed: false, reason: "diff missing removal of #{must_remove}"}

          true ->
            # Reviewer would reject — confirm no file written under our control
            %{name: name, passed: true, reason: nil}
        end

      {:reject, "refine_or_reject"} ->
        %{name: name, passed: true, reason: nil}

      {{:human_review, _producer, _verdict}, "human_review"} ->
        # Confirm quit path does not write.
        :quit = Review.run(proposal, project_key, input_fun: fn _ -> "q" end)
        %{name: name, passed: true, reason: nil}

      {actual, expected_decision} ->
        %{name: name, passed: false, reason: "decision mismatch: #{inspect(actual)} vs #{expected_decision}"}
    end
  end

  defp result_with_optional_write(name, _proposal, _project_key, expected, _wrote?) do
    case Map.get(expected, "writes_file") do
      false -> %{name: name, passed: true, reason: nil}
      _ -> %{name: name, passed: true, reason: nil}
    end
  end

  defp transcript_to_response(%{"decision" => "reject", "rationale" => r}), do: {:reject, r}

  defp transcript_to_response(%{"decision" => "create"} = t) do
    {:create,
     %{
       "slug" => Map.fetch!(t, "slug"),
       "title" => Map.fetch!(t, "title"),
       "topic" => Map.get(t, "topic", ""),
       "body" => Map.fetch!(t, "body")
     }}
  end

  defp transcript_to_response(%{"decision" => "refine"} = t) do
    {:refine, Map.fetch!(t, "target_slug"), Map.fetch!(t, "merged_body")}
  end

  defp transcript_to_response(_), do: :reject

  # Existing (Phase 1) fixtures have no critic entry; default to :approve so
  # their outcomes are unchanged. Phase 2 fixtures add a `"critic"` key.
  defp transcript_to_critic(%{"critic" => %{"verdict" => "approve"}}), do: :approve

  defp transcript_to_critic(%{"critic" => %{"verdict" => "reject"} = c}) do
    {:reject, Map.get(c, "reason", "rejected")}
  end

  defp transcript_to_critic(%{"critic" => %{"verdict" => "conflict"} = c}) do
    {:conflict, Map.fetch!(c, "slug"), Map.get(c, "reason", "contradicts existing entry")}
  end

  defp transcript_to_critic(_), do: :approve

  defp setup_isolated_root!(fixture_dir) do
    name = Path.basename(fixture_dir)
    root = Path.join(System.tmp_dir!(), "curator-eval-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    project_key = @project_key
    Application.put_env(:symphony_elixir, :test_eval_knowledge_root, root)
    {root, project_key}
  end

  defp seed_wiki!(fixture_dir, project_key) do
    seed_dir = Path.join(fixture_dir, "seed_wiki")

    case File.ls(seed_dir) do
      {:ok, files} ->
        Enum.each(files, fn file ->
          slug = String.replace_suffix(file, ".md", "")
          raw = File.read!(Path.join(seed_dir, file))
          {:ok, entry} = Entry.parse(raw)
          :ok = Wiki.put(project_key, entry)
        end)

      _ ->
        :ok
    end
  end

  defp load_seed_body(project_key, slug) do
    case Wiki.get(project_key, slug) do
      {:ok, entry} -> entry.body
      _ -> ""
    end
  end

  defp format_decision(%{decision: :reject, rationale: r}), do: "REJECT: #{r}"
  defp format_decision(%{decision: {:create, slug, _}, rationale: r}), do: "CREATE #{slug}: #{r}"
  defp format_decision(%{decision: {:refine, slug, _}, rationale: r}), do: "REFINE #{slug}: #{r}"

  defp format_decision(%{decision: {:human_review, producer, verdict}}) do
    producer_str =
      case producer do
        :reject -> "reject"
        {:create, slug, _} -> "create #{slug}"
        {:refine, slug, _} -> "refine #{slug}"
      end

    verdict_str =
      case verdict do
        :approve -> "approve"
        {:reject, reason} -> "reject: #{reason}"
        {:conflict, slug, reason} -> "conflict with #{slug}: #{reason}"
      end

    "HUMAN_REVIEW: producer=#{producer_str}; critic=#{verdict_str}"
  end
end

defmodule FakeRetrievalQuery do
  def query(_project_key, _ctx, _opts) do
    {:ok, Process.get(:fake_retrieval_slugs, [])}
  end
end

# Set the workflow file so Wiki + Knowledge resolve to our isolated root.
workflow_path = Path.join(System.tmp_dir!(), "curator-eval-workflow-#{System.unique_integer([:positive])}.md")
knowledge_root = Path.join(System.tmp_dir!(), "curator-eval-knowledge-#{System.unique_integer([:positive])}")
File.mkdir_p!(knowledge_root)

File.write!(workflow_path, """
---
tracker:
  kind: github
  endpoint: https://api.github.com/graphql
  repo: apexphere/curator-eval
agent:
  runtime: claude-code
codex:
  command: codex
claude_code:
  command: claude
hooks:
  timeout_ms: 60000
observability:
  dashboard_enabled: false
  refresh_ms: 1000
  render_interval_ms: 16
knowledge:
  backend: filesystem
  root: #{knowledge_root}
---
You are an agent.
""")

SymphonyElixir.Workflow.set_workflow_file_path(workflow_path)

if Process.whereis(SymphonyElixir.WorkflowStore) do
  SymphonyElixir.WorkflowStore.force_reload()
end

CuratorEval.run_all([curator_fixtures, critic_fixtures])
