defmodule SymphonyElixir.ClaudeCode.RunnerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ClaudeCode.Runner

  defp setup_workspace(test_root, fake_script_body, opts \\ []) do
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-#{System.unique_integer([:positive])}")
    fake_claude_dir = Path.join(test_root, "bin")
    fake_claude_path = Path.join(fake_claude_dir, "claude")

    File.mkdir_p!(workspace)
    File.mkdir_p!(fake_claude_dir)
    File.write!(fake_claude_path, fake_script_body)
    File.chmod!(fake_claude_path, 0o755)

    # Prepend fake bin to PATH so System.find_executable picks it up
    previous_path = System.get_env("PATH")
    System.put_env("PATH", fake_claude_dir <> ":" <> (previous_path || ""))

    on_exit(fn ->
      if is_binary(previous_path) do
        System.put_env("PATH", previous_path)
      else
        System.delete_env("PATH")
      end
    end)

    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(
        [
          workspace_root: workspace_root,
          claude_code_command: "claude",
          claude_code_turn_timeout_ms: 5_000,
          agent_runtime: "claude-code"
        ],
        opts
      )
    )

    {workspace, fake_claude_path}
  end

  defp default_issue do
    %Issue{
      id: "issue-claude-1",
      identifier: "MT-1",
      title: "Test issue",
      description: "Verify claude runner",
      state: "In Progress",
      url: "https://example.org/issues/MT-1",
      labels: ["backend"]
    }
  end

  test "runs a turn and returns turn_completed on success" do
    test_root = Path.join(System.tmp_dir!(), "symp-claude-success-#{System.unique_integer([:positive])}")

    try do
      script = """
      #!/bin/sh
      printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-1","tools":[]}'
      printf '%s\\n' '{"type":"assistant","message":{"usage":{"input_tokens":5,"output_tokens":3}}}'
      printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"session_id":"sess-1","num_turns":1,"usage":{"input_tokens":5,"output_tokens":3}}'
      exit 0
      """

      {workspace, _bin} = setup_workspace(test_root, script)
      messages = []
      pid = self()

      on_message = fn msg ->
        send(pid, {:claude_event, msg.event, msg})
        :ok
      end

      assert {:ok, result} =
               Runner.run_turn(workspace, "do the thing", default_issue(), on_message: on_message)

      assert result.result == :turn_completed
      assert result.session_id == "sess-1"
      assert is_map(result.usage)

      assert_received {:claude_event, :session_started, _}
      assert_received {:claude_event, :assistant_message, msg}
      assert msg.usage == %{"input_tokens" => 5, "output_tokens" => 3}
      assert_received {:claude_event, :turn_completed, _}

      _ = messages
    after
      File.rm_rf(test_root)
    end
  end

  test "returns error when claude exits non-zero" do
    test_root = Path.join(System.tmp_dir!(), "symp-claude-fail-#{System.unique_integer([:positive])}")

    try do
      script = """
      #!/bin/sh
      printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-fail"}'
      exit 7
      """

      {workspace, _bin} = setup_workspace(test_root, script)

      assert {:error, {:claude_exit_status, 7}} =
               Runner.run_turn(workspace, "fail please", default_issue())
    after
      File.rm_rf(test_root)
    end
  end

  test "returns turn_failed when result event has is_error true" do
    test_root = Path.join(System.tmp_dir!(), "symp-claude-result-error-#{System.unique_integer([:positive])}")

    try do
      script = """
      #!/bin/sh
      printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-err"}'
      printf '%s\\n' '{"type":"result","subtype":"error","is_error":true,"session_id":"sess-err","result":"boom"}'
      exit 0
      """

      {workspace, _bin} = setup_workspace(test_root, script)

      assert {:error, {:turn_failed, payload}} =
               Runner.run_turn(workspace, "do bad thing", default_issue())

      assert payload["is_error"] == true
    after
      File.rm_rf(test_root)
    end
  end

  test "returns turn_timeout when subprocess exceeds turn_timeout_ms" do
    test_root = Path.join(System.tmp_dir!(), "symp-claude-timeout-#{System.unique_integer([:positive])}")

    try do
      script = """
      #!/bin/sh
      sleep 10
      """

      {workspace, _bin} = setup_workspace(test_root, script,
        claude_code_turn_timeout_ms: 200,
        claude_code_stall_timeout_ms: 1_000
      )

      assert {:error, :turn_timeout} =
               Runner.run_turn(workspace, "slow", default_issue())
    after
      File.rm_rf(test_root)
    end
  end

  test "returns turn_stalled when subprocess produces no output for stall_timeout_ms" do
    test_root = Path.join(System.tmp_dir!(), "symp-claude-stall-#{System.unique_integer([:positive])}")

    try do
      # Print the init event so a session is established, then sleep without
      # producing more output. Stall watchdog should fire well before the
      # generous turn timeout.
      script = """
      #!/bin/sh
      printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-stall"}'
      sleep 30
      """

      {workspace, _bin} = setup_workspace(test_root, script,
        claude_code_turn_timeout_ms: 60_000,
        claude_code_stall_timeout_ms: 200
      )

      pid = self()
      on_message = fn msg -> send(pid, {:claude_event, msg.event}); :ok end

      assert {:error, :turn_stalled} =
               Runner.run_turn(workspace, "stall", default_issue(), on_message: on_message)

      assert_received {:claude_event, :session_started}
      assert_received {:claude_event, :turn_ended_with_error}
    after
      File.rm_rf(test_root)
    end
  end

  test "stall_deadline refreshes on every output, so steady streams complete" do
    test_root = Path.join(System.tmp_dir!(), "symp-claude-steady-#{System.unique_integer([:positive])}")

    try do
      # Emit init, then a message every ~50ms for 200ms (well under 500ms stall),
      # then result + exit. Stall watchdog should NOT fire.
      script = """
      #!/bin/sh
      printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-steady"}'
      i=0
      while [ $i -lt 4 ]; do
        printf '%s\\n' '{"type":"assistant","message":{"usage":{"input_tokens":1,"output_tokens":1}}}'
        sleep 0.05
        i=$((i + 1))
      done
      printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"session_id":"sess-steady","usage":{"input_tokens":4,"output_tokens":4}}'
      exit 0
      """

      {workspace, _bin} = setup_workspace(test_root, script,
        claude_code_turn_timeout_ms: 5_000,
        claude_code_stall_timeout_ms: 500
      )

      assert {:ok, %{result: :turn_completed}} =
               Runner.run_turn(workspace, "steady", default_issue())
    after
      File.rm_rf(test_root)
    end
  end

  test "tolerates non-JSON output lines" do
    test_root = Path.join(System.tmp_dir!(), "symp-claude-malformed-#{System.unique_integer([:positive])}")

    try do
      script = """
      #!/bin/sh
      printf '%s\\n' 'warning: something happened (not JSON)'
      printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-malformed"}'
      printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"session_id":"sess-malformed","usage":{"input_tokens":1,"output_tokens":1}}'
      exit 0
      """

      {workspace, _bin} = setup_workspace(test_root, script)
      pid = self()

      on_message = fn msg ->
        send(pid, {:claude_event, msg.event})
        :ok
      end

      assert {:ok, %{result: :turn_completed}} =
               Runner.run_turn(workspace, "test", default_issue(), on_message: on_message)

      assert_received {:claude_event, :malformed}
      assert_received {:claude_event, :session_started}
      assert_received {:claude_event, :turn_completed}
    after
      File.rm_rf(test_root)
    end
  end

  test "returns error when claude binary is not found" do
    test_root =
      Path.join(System.tmp_dir!(), "symp-claude-missing-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-missing")
      File.mkdir_p!(workspace)

      previous_path = System.get_env("PATH")
      System.put_env("PATH", "/nonexistent-bin")

      on_exit(fn ->
        if is_binary(previous_path) do
          System.put_env("PATH", previous_path)
        else
          System.delete_env("PATH")
        end
      end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_code_command: "claude-does-not-exist",
        agent_runtime: "claude-code"
      )

      assert {:error, {:claude_command_not_found, "claude-does-not-exist"}} =
               Runner.run_turn(workspace, "test", default_issue())
    after
      File.rm_rf(test_root)
    end
  end

  test "rejects workspace root and outside-root paths" do
    test_root =
      Path.join(System.tmp_dir!(), "symp-claude-cwd-guard-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_workspace = Path.join(test_root, "outside")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_runtime: "claude-code"
      )

      assert {:error, {:invalid_workspace_cwd, :workspace_root, _}} =
               Runner.run_turn(workspace_root, "test", default_issue())

      assert {:error, {:invalid_workspace_cwd, :outside_root, _}} =
               Runner.run_turn(outside_workspace, "test", default_issue())
    after
      File.rm_rf(test_root)
    end
  end
end
