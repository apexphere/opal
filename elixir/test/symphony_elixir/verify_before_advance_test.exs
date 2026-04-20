defmodule SymphonyElixir.VerifyBeforeAdvanceTest do
  use SymphonyElixir.TestSupport

  @moduledoc """
  Exercises the verify-before-advance flow: when a running issue's tracker state
  moves to terminal, the workspace must be preserved and verification must run
  before claim release / workspace cleanup. On verify fail, the tracker must be
  reverted so the run can redispatch against the same workspace.

  Covers the root cause of the 2026-04-20 adversarial dogfood F2 finding.
  """

  setup do
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_executor = Application.get_env(:symphony_elixir, :verification_executor_module)

    on_exit(fn ->
      restore(previous_memory_issues, :memory_tracker_issues)
      restore(previous_memory_recipient, :memory_tracker_recipient)
      restore(previous_executor, :verification_executor_module)
    end)

    :ok
  end

  defp restore(nil, key), do: Application.delete_env(:symphony_elixir, key)
  defp restore(value, key), do: Application.put_env(:symphony_elixir, key, value)

  defp fresh_workspace_root(tag) do
    Path.join(
      System.tmp_dir!(),
      "opal-verify-before-advance-#{tag}-#{System.unique_integer([:positive])}"
    )
  end

  defp workspace_for(root, identifier) do
    path = Path.join(root, identifier)
    File.mkdir_p!(path)
    path
  end

  defp write_recipe!(workspace, steps) do
    File.mkdir_p!(Path.join(workspace, ".opal"))
    File.write!(Path.join(workspace, ".opal/verify.json"), Jason.encode!(%{"steps" => steps}))
  end

  defp running_entry(workspace, issue_id, identifier, agent_pid, ref \\ nil) do
    %{
      pid: agent_pid,
      ref: ref,
      identifier: identifier,
      issue: %Issue{id: issue_id, identifier: identifier, state: "In Progress"},
      workspace_path: workspace,
      worker_host: nil,
      started_at: DateTime.utc_now()
    }
  end

  defp terminal_issue(issue_id, identifier) do
    %Issue{
      id: issue_id,
      identifier: identifier,
      state: "Closed",
      title: "Done",
      description: "Closed by agent",
      labels: []
    }
  end

  defp spawn_agent do
    spawn(fn ->
      receive do
        :stop -> :ok
      after
        60_000 -> :ok
      end
    end)
  end

  defp wait_until(fun, attempts \\ 80, delay_ms \\ 25)
  defp wait_until(_fun, 0, _delay_ms), do: :timeout

  defp wait_until(fun, attempts, delay_ms) do
    if fun.() do
      :ok
    else
      Process.sleep(delay_ms)
      wait_until(fun, attempts - 1, delay_ms)
    end
  end

  test "reconcile-terminal with verification disabled cleans up workspace" do
    # Regression guard: the pre-F2 behaviour (straight cleanup) must still apply
    # when verification.enabled is false (the schema default).
    root = fresh_workspace_root("disabled")
    identifier = "OPAL-1001"
    workspace = workspace_for(root, identifier)
    issue_id = "issue-disabled"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: root
    )

    state = %Orchestrator.State{
      running: %{issue_id => running_entry(workspace, issue_id, identifier, spawn_agent())},
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{},
      verifying: %{}
    }

    updated = Orchestrator.reconcile_issue_states_for_test([terminal_issue(issue_id, identifier)], state)

    refute Map.has_key?(updated.running, issue_id)
    refute Map.has_key?(updated.verifying, issue_id)
    refute MapSet.member?(updated.claimed, issue_id)
    refute File.exists?(workspace)

    File.rm_rf(root)
  end

  test "reconcile-terminal with verification enabled preserves workspace while verifying, then cleans up on pass" do
    root = fresh_workspace_root("pass")
    identifier = "OPAL-1002"
    workspace = workspace_for(root, identifier)
    write_recipe!(workspace, [%{"name" => "ok", "shell" => "true"}])

    issue_id = "issue-pass"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: root,
      verification_enabled: true
    )

    orchestrator_name = Module.concat(__MODULE__, :PassOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      File.rm_rf(root)
    end)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [terminal_issue(issue_id, identifier)])

    :sys.replace_state(pid, fn state ->
      state
      |> Map.put(:running, %{issue_id => running_entry(workspace, issue_id, identifier, spawn_agent())})
      |> Map.put(:claimed, MapSet.new([issue_id]))
    end)

    # Trigger reconcile via the poll cycle. reconcile_running_issues fetches
    # memory-tracker state, sees terminal, and routes through verify.
    send(pid, :run_poll_cycle)

    :ok =
      wait_until(fn ->
        state = :sys.get_state(pid)
        not Map.has_key?(state.verifying, issue_id) and not File.exists?(workspace)
      end)

    state = :sys.get_state(pid)
    refute Map.has_key?(state.running, issue_id)
    refute MapSet.member?(state.claimed, issue_id)
    refute File.exists?(workspace)
  end

  test "reconcile-terminal with failing recipe reverts tracker and preserves workspace" do
    root = fresh_workspace_root("fail")
    identifier = "OPAL-1003"
    workspace = workspace_for(root, identifier)
    write_recipe!(workspace, [%{"name" => "boom", "shell" => "false"}])

    issue_id = "issue-fail"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: root,
      verification_enabled: true,
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Closed"]
    )

    orchestrator_name = Module.concat(__MODULE__, :FailOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      File.rm_rf(root)
    end)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [terminal_issue(issue_id, identifier)])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    :sys.replace_state(pid, fn state ->
      state
      |> Map.put(:running, %{issue_id => running_entry(workspace, issue_id, identifier, spawn_agent())})
      |> Map.put(:claimed, MapSet.new([issue_id]))
    end)

    send(pid, :run_poll_cycle)

    # Verify fail reverts tracker to the last configured active state.
    assert_receive {:memory_tracker_state_update, ^issue_id, "In Progress"}, 2_000

    :ok =
      wait_until(fn ->
        state = :sys.get_state(pid)
        not Map.has_key?(state.verifying, issue_id)
      end)

    state = :sys.get_state(pid)
    refute Map.has_key?(state.running, issue_id)
    refute Map.has_key?(state.verifying, issue_id)
    assert File.exists?(workspace), "workspace must survive verify fail so agent can retry"
    # Retry is scheduled so the reverted issue will be picked up again.
    assert Map.has_key?(state.retry_attempts, issue_id)
  end

  test "continuation-retry terminal check routes through verify" do
    root = fresh_workspace_root("cont")
    identifier = "OPAL-1004"
    workspace = workspace_for(root, identifier)
    write_recipe!(workspace, [%{"name" => "ok", "shell" => "true"}])

    issue_id = "issue-cont"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: root,
      verification_enabled: true
    )

    orchestrator_name = Module.concat(__MODULE__, :ContinuationOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      File.rm_rf(root)
    end)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [terminal_issue(issue_id, identifier)])

    ref = make_ref()
    running = running_entry(workspace, issue_id, identifier, spawn_agent(), ref)

    :sys.replace_state(pid, fn state ->
      state
      |> Map.put(:running, %{issue_id => running})
      |> Map.put(:claimed, MapSet.new([issue_id]))
    end)

    # :DOWN :normal triggers the continuation-retry path. The scheduled retry
    # fires after 1s, refetches tracker state, sees terminal, and must route
    # through verify (rather than cleaning the workspace directly).
    send(pid, {:DOWN, ref, :process, running.pid, :normal})

    :ok =
      wait_until(
        fn ->
          state = :sys.get_state(pid)

          not Map.has_key?(state.running, issue_id) and
            not Map.has_key?(state.verifying, issue_id) and
            not File.exists?(workspace)
        end,
        200,
        25
      )

    state = :sys.get_state(pid)
    refute File.exists?(workspace)
    refute MapSet.member?(state.claimed, issue_id)
  end

  defmodule CrashingExecutor do
    @behaviour SymphonyElixir.Verification.Executor

    @impl true
    def run_step(_step, _workspace, _opts), do: raise("executor boom")
  end

  test "verification task crash is treated as skipped and releases the claim" do
    # If the verify task itself dies before sending :verification_done, the
    # orchestrator's :DOWN handler must still move the issue out of :verifying
    # rather than wedging the claim forever.
    root = fresh_workspace_root("crash")
    identifier = "OPAL-1005"
    workspace = workspace_for(root, identifier)
    write_recipe!(workspace, [%{"name" => "will-crash", "shell" => "true"}])

    issue_id = "issue-crash"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: root,
      verification_enabled: true
    )

    orchestrator_name = Module.concat(__MODULE__, :CrashOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      File.rm_rf(root)
    end)

    Application.put_env(:symphony_elixir, :verification_executor_module, CrashingExecutor)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [terminal_issue(issue_id, identifier)])

    :sys.replace_state(pid, fn state ->
      state
      |> Map.put(:running, %{issue_id => running_entry(workspace, issue_id, identifier, spawn_agent())})
      |> Map.put(:claimed, MapSet.new([issue_id]))
    end)

    send(pid, :run_poll_cycle)

    :ok =
      wait_until(fn ->
        state = :sys.get_state(pid)
        not Map.has_key?(state.verifying, issue_id)
      end)

    state = :sys.get_state(pid)
    refute Map.has_key?(state.running, issue_id)
    refute Map.has_key?(state.verifying, issue_id)
    refute MapSet.member?(state.claimed, issue_id)
  end
end
