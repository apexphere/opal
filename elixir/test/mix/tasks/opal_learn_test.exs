defmodule Mix.Tasks.Opal.LearnTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureIO

  alias Mix.Tasks.Opal.Learn

  setup do
    Mix.Task.reenable("opal.learn")

    test_root =
      Path.join(
        System.tmp_dir!(),
        "opal-learn-task-#{System.unique_integer([:positive])}"
      )

    knowledge_root = Path.join(test_root, "knowledge")
    File.mkdir_p!(knowledge_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "apexphere/opal-learn-task",
      knowledge_root: knowledge_root
    )

    Application.put_env(:symphony_elixir, :curator_distiller_module, SymphonyElixir.Curator.Distillers.Stub)
    Application.put_env(:symphony_elixir, :curator_critic_module, SymphonyElixir.Curator.Critics.Stub)
    Application.put_env(:symphony_elixir, :curator_stub_critic, :approve)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :curator_distiller_module)
      Application.delete_env(:symphony_elixir, :curator_critic_module)
      Application.delete_env(:symphony_elixir, :curator_stub_response)
      Application.delete_env(:symphony_elixir, :curator_stub_critic)
      File.rm_rf(test_root)
    end)

    article_path = Path.join(test_root, "article.md")
    File.write!(article_path, "# Article\n\nbody about something\n")

    %{test_root: test_root, article_path: article_path}
  end

  test "prints help" do
    output = capture_io(fn -> Learn.run(["--help"]) end)
    assert output =~ "mix opal.learn"
  end

  test "fails on invalid options" do
    assert_raise Mix.Error, ~r/Invalid option/, fn -> Learn.run(["--wat"]) end
  end

  test "fails when no article path is given" do
    assert_raise Mix.Error, ~r/Usage:/, fn -> Learn.run([]) end
  end

  test "auto-accepts a create proposal end-to-end", ctx do
    Application.put_env(
      :symphony_elixir,
      :curator_stub_response,
      {:create,
       %{
         "slug" => "new-thing",
         "title" => "New thing",
         "topic" => "topic",
         "body" => "# New\n\nbody\n"
       }}
    )

    output =
      capture_io(fn ->
        Learn.run([ctx.article_path, "--project", "github_apexphere_opal-learn-task", "--auto-accept"])
      end)

    assert output =~ "CREATE new-thing"
    assert output =~ "Wrote wiki/new-thing.md"
    assert SymphonyElixir.Wiki.exists?("github_apexphere_opal-learn-task", "new-thing")
  end

  test "auto-accept on reject is a no-op", ctx do
    Application.put_env(:symphony_elixir, :curator_stub_response, {:reject, "off topic"})

    output =
      capture_io(fn ->
        Learn.run([ctx.article_path, "--project", "github_apexphere_opal-learn-task", "--auto-accept"])
      end)

    assert output =~ "REJECT"
    assert output =~ "no write"
  end

  test "prints curator error when learn returns error", ctx do
    huge = String.duplicate("a", SymphonyElixir.Curator.max_article_bytes() + 1)
    File.write!(ctx.article_path, huge)
    Application.put_env(:symphony_elixir, :curator_stub_response, :reject)

    output =
      capture_io(:stderr, fn ->
        Learn.run([ctx.article_path, "--project", "github_apexphere_opal-learn-task", "--auto-accept"])
      end)

    assert output =~ "Curator failed"
  end

  test "without --auto-accept drops into the interactive Review (fed via stdin)", ctx do
    Application.put_env(
      :symphony_elixir,
      :curator_stub_response,
      {:create,
       %{
         "slug" => "interactive-thing",
         "title" => "Interactive",
         "topic" => "topic",
         "body" => "body\n"
       }}
    )

    # "r\n" rejects at the Review prompt — exercises the non-auto-accept
    # branch (Review.run/2) without writing the entry.
    output =
      capture_io("r\n", fn ->
        Learn.run([ctx.article_path, "--project", "github_apexphere_opal-learn-task"])
      end)

    assert output =~ "CREATE interactive-thing"
    refute SymphonyElixir.Wiki.exists?("github_apexphere_opal-learn-task", "interactive-thing")
  end

  test "formats a HUMAN_REVIEW decision when producer and critic disagree", ctx do
    Application.put_env(
      :symphony_elixir,
      :curator_stub_response,
      {:create,
       %{
         "slug" => "human-review-thing",
         "title" => "HR",
         "topic" => "topic",
         "body" => "b\n"
       }}
    )

    # Conflict slug doesn't need to exist — Stub critic bypasses candidate
    # validation (only the Consistency critic enforces that).
    Application.put_env(
      :symphony_elixir,
      :curator_stub_critic,
      {:conflict, "other-slug", "contradicts other"}
    )

    # Feed "q\n" to Review.run so human_review_loop quits without writing.
    output =
      capture_io("q\n", fn ->
        Learn.run([ctx.article_path, "--project", "github_apexphere_opal-learn-task"])
      end)

    assert output =~ "HUMAN REVIEW"
    refute SymphonyElixir.Wiki.exists?("github_apexphere_opal-learn-task", "human-review-thing")
  end

  test "formats a REFINE decision", ctx do
    # Seed the refine target so curator's sanitize_proposal accepts it.
    :ok =
      SymphonyElixir.Wiki.put(
        "github_apexphere_opal-learn-task",
        %SymphonyElixir.Wiki.Entry{
          slug: "auth-tokens",
          title: "Auth tokens",
          topic: "security",
          revision: 1,
          created_at: "2026-04-20T00:00:00Z",
          updated_at: "2026-04-20T00:00:00Z",
          body: "# v1\n\nold body\n"
        }
      )

    Application.put_env(
      :symphony_elixir,
      :curator_stub_response,
      {:refine, "auth-tokens", "# v2\n\nmerged\n"}
    )

    output =
      capture_io(fn ->
        Learn.run([ctx.article_path, "--project", "github_apexphere_opal-learn-task", "--auto-accept"])
      end)

    assert output =~ "REFINE auth-tokens"
  end
end
