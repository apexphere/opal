defmodule SymphonyElixir.ClaudeCode.E2ETest do
  @moduledoc """
  End-to-end test for the Claude Code adapter against the real `claude` CLI.

  Requires `claude` on PATH. Skipped by default (tagged :e2e). Run with:

      mix test test/symphony_elixir/claude_code/e2e_test.exs --include e2e
  """
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ClaudeCode.Runner

  @moduletag :e2e
  @moduletag timeout: 300_000

  setup do
    if is_nil(System.find_executable("claude")) do
      raise "claude CLI required for e2e tests"
    end

    test_root =
      Path.join(System.tmp_dir!(), "symp-claude-e2e-#{System.unique_integer([:positive])}")

    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-1")
    File.mkdir_p!(workspace)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      agent_runtime: "claude-code",
      claude_code_command: "claude",
      claude_code_allowed_tools: "Edit,Write,Read,Bash,Glob,Grep",
      claude_code_permission_mode: "bypassPermissions",
      claude_code_turn_timeout_ms: 120_000
    )

    on_exit(fn -> File.rm_rf(test_root) end)

    {:ok, workspace: workspace, test_root: test_root}
  end

  test "runs a real claude turn that creates a file in the workspace", %{workspace: workspace} do
    issue = %Issue{
      id: "issue-e2e-1",
      identifier: "MT-1",
      title: "E2E test",
      description: "End-to-end smoke test",
      state: "In Progress",
      url: "https://example.org/issues/MT-1",
      labels: []
    }

    pid = self()

    on_message = fn msg ->
      send(pid, {:claude_event, msg.event})
      :ok
    end

    prompt = """
    Create a file named HELLO.txt in the current directory with exactly the content:
    hello from opal e2e test

    Then exit. Do not ask for confirmation.
    """

    assert {:ok, result} =
             Runner.run_turn(workspace, prompt, issue, on_message: on_message)

    assert result.result == :turn_completed
    assert is_binary(result.session_id)
    assert is_map(result.usage)

    # Verify file actually got created
    hello_file = Path.join(workspace, "HELLO.txt")
    assert File.exists?(hello_file), "Expected #{hello_file} to exist after claude turn"

    contents = File.read!(hello_file) |> String.trim()
    assert contents =~ "hello from opal e2e test"

    # Verify event sequence
    assert_received {:claude_event, :session_started}
    assert_received {:claude_event, :turn_completed}
  end
end
