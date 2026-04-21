defmodule SymphonyElixir.GoldenPathTest do
  use SymphonyElixir.TestSupport

  @moduledoc """
  Exercises Opal's golden path with local fakes at the external boundary:

  memory tracker -> real orchestrator -> real workspace -> fake Claude Code ->
  real verification -> real workspace cleanup.

  This intentionally avoids GitHub, network access, and the real `claude`
  binary while proving the product-shaped flow stays wired together.
  """

  defmodule FakeClaudeRunner do
    @moduledoc false

    alias SymphonyElixir.Linear.Issue

    @spec run_turn(Path.t(), String.t(), Issue.t(), keyword()) :: {:ok, map()}
    def run_turn(workspace, prompt, %Issue{} = issue, opts) do
      recipient = Application.fetch_env!(:symphony_elixir, :golden_path_test_recipient)
      send(recipient, {:fake_claude_turn, workspace, prompt})

      write_verification_recipe!(workspace, issue.identifier)
      mark_issue_closed!(issue)

      on_message = Keyword.get(opts, :on_message, fn _message -> :ok end)
      session_id = "fake-claude-#{issue.id}"

      on_message.(%{
        event: :session_started,
        timestamp: DateTime.utc_now(),
        session_id: session_id,
        claude_code_pid: "fake"
      })

      on_message.(%{
        event: :turn_completed,
        timestamp: DateTime.utc_now(),
        session_id: session_id,
        usage: %{"input_tokens" => 12, "output_tokens" => 8, "total_tokens" => 20}
      })

      {:ok,
       %{
         result: :turn_completed,
         session_id: session_id,
         usage: %{"input_tokens" => 12, "output_tokens" => 8, "total_tokens" => 20}
       }}
    end

    defp write_verification_recipe!(workspace, identifier) do
      File.mkdir_p!(Path.join(workspace, ".opal"))

      File.write!(
        Path.join(workspace, ".opal/verify.json"),
        Jason.encode!(%{
          "version" => "1",
          "description" => "golden path workspace proof",
          "steps" => [
            %{
              "name" => "workspace has cloned repo and issue branch",
              "shell" => "test -f README.md && test \"$(git branch --show-current)\" = \"opal/#{identifier}\"",
              "expect_exit" => 0
            }
          ]
        })
      )
    end

    defp mark_issue_closed!(%Issue{} = issue) do
      closed = %Issue{issue | state: "Closed", labels: []}
      # Seed future fetches with the terminal issue while also emitting the
      # tracker transition event the test asserts.
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [closed])
      :ok = SymphonyElixir.Tracker.update_issue_state(issue.id, "Closed")
    end
  end

  setup do
    previous_runner = Application.get_env(:symphony_elixir, :claude_code_runner_module)
    previous_recipient = Application.get_env(:symphony_elixir, :golden_path_test_recipient)
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_curator_flag = Application.get_env(:symphony_elixir, :curator_auto_learn_from_failures)

    Application.put_env(:symphony_elixir, :claude_code_runner_module, FakeClaudeRunner)
    Application.put_env(:symphony_elixir, :golden_path_test_recipient, self())
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :curator_auto_learn_from_failures, false)

    on_exit(fn ->
      restore_app_env(:claude_code_runner_module, previous_runner)
      restore_app_env(:golden_path_test_recipient, previous_recipient)
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      restore_app_env(:curator_auto_learn_from_failures, previous_curator_flag)
    end)

    :ok
  end

  test "runs one issue through fake Claude, branch setup, and verification" do
    test_root = fresh_root()
    source_repo = Path.join(test_root, "source")
    workspace_root = Path.join(test_root, "workspaces")
    branch_capture = Path.join(test_root, "verified-branch.txt")
    log_capture = Path.join(test_root, "verify-log.json")
    hook_capture = Path.join(test_root, "pre-push-hook.txt")

    try do
      create_source_repo!(source_repo)
      File.mkdir_p!(workspace_root)

      issue = golden_issue()
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["Todo", "In Progress"],
        tracker_terminal_states: ["Closed"],
        workspace_root: workspace_root,
        hook_after_create: "git clone --depth 1 #{source_repo} .",
        hook_before_remove: before_remove_capture_hook(branch_capture, log_capture, hook_capture),
        agent_runtime: "claude-code",
        max_concurrent_agents: 1,
        max_turns: 1,
        verification_enabled: true,
        verification_required: true,
        verification_step_timeout_ms: 5_000
      )

      orchestrator_name = Module.concat(__MODULE__, :GoldenPathOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid), do: Process.exit(pid, :normal)
      end)

      Orchestrator.request_refresh(orchestrator_name)

      assert_receive {:fake_claude_turn, workspace, prompt}, 2_000
      assert Path.basename(workspace) == issue.identifier
      assert prompt =~ "Verification step (required before declaring done)"

      assert_receive {:memory_tracker_state_update, "issue-golden-1", "Closed"}, 1_000

      assert :ok =
               wait_until(fn ->
                 File.exists?(log_capture) and not File.exists?(workspace)
               end)

      assert File.read!(branch_capture) == "opal/#{issue.identifier}\n"
      assert File.read!(hook_capture) == "pre-push installed\n"

      verify_log = log_capture |> File.read!() |> Jason.decode!()
      assert verify_log["status"] == "pass"

      assert [
               %{
                 "name" => "workspace has cloned repo and issue branch",
                 "passed" => true,
                 "exit" => 0
               }
             ] = verify_log["steps"]

      state = :sys.get_state(pid)
      refute Map.has_key?(state.running, issue.id)
      refute Map.has_key?(state.verifying, issue.id)
      refute Map.has_key?(state.retry_attempts, issue.id)
      refute MapSet.member?(state.claimed, issue.id)
      assert MapSet.member?(state.completed, issue.id)
    after
      File.rm_rf(test_root)
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp fresh_root do
    Path.join(System.tmp_dir!(), "opal-golden-path-#{System.unique_integer([:positive])}")
  end

  defp golden_issue do
    %Issue{
      id: "issue-golden-1",
      identifier: "OPAL-47",
      title: "Exercise the golden path",
      description: "Prove the default flow with local fakes.",
      state: "Todo",
      url: "https://github.com/apexphere/opal/issues/47",
      labels: ["todo"],
      created_at: ~U[2026-04-21 00:00:00Z]
    }
  end

  defp create_source_repo!(source_repo) do
    File.mkdir_p!(source_repo)
    File.write!(Path.join(source_repo, "README.md"), "# Golden path fixture\n")
    run_git!(source_repo, ["init", "-b", "main"])
    run_git!(source_repo, ["config", "user.name", "Test User"])
    run_git!(source_repo, ["config", "user.email", "test@example.com"])
    run_git!(source_repo, ["add", "README.md"])
    run_git!(source_repo, ["commit", "-m", "initial"])
  end

  defp run_git!(cwd, args) do
    case System.cmd("git", ["-C", cwd | args], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed #{status}: #{output}")
    end
  end

  defp before_remove_capture_hook(branch_capture, log_capture, hook_capture) do
    """
    git branch --show-current > #{shell_escape(branch_capture)}
    cp .opal/verify-log.json #{shell_escape(log_capture)}
    test -x .git/hooks/pre-push
    printf 'pre-push installed\\n' > #{shell_escape(hook_capture)}
    """
  end

  defp shell_escape(path) do
    "'" <> String.replace(path, "'", "'\"'\"'") <> "'"
  end

  defp wait_until(fun, attempts \\ 200, delay_ms \\ 25)
  defp wait_until(_fun, 0, _delay_ms), do: :timeout

  defp wait_until(fun, attempts, delay_ms) do
    if fun.() do
      :ok
    else
      Process.sleep(delay_ms)
      wait_until(fun, attempts - 1, delay_ms)
    end
  end
end
