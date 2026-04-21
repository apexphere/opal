defmodule SymphonyElixir.OrchestratorCriticTest do
  @moduledoc """
  Exercises the `:rejected` outcome handling inside the orchestrator:
  * retry cap (default 2) on repeated critic rejections,
  * task_summary + diff plumbing into the verify-settings bag,
  * clean-slate rejection counter on non-rejected outcomes.

  These tests run against `apply_verification_outcome_for_test/5` and
  `build_verify_settings_for_test/3` so they can isolate behaviour from
  the full poll/dispatch loop.
  """
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema.Verification, as: VerificationSettings

  setup do
    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end)

    :ok
  end

  defp base_state(issue_id, identifier) do
    %Orchestrator.State{
      claimed: MapSet.new([issue_id]),
      verifying: %{},
      retry_attempts: %{},
      critic_rejection_attempts: %{},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      completed: MapSet.new(),
      running: %{},
      max_concurrent_agents: 1
    }
    |> tap(fn _ -> issue_id end)
    |> tap(fn _ -> identifier end)
  end

  defp entry(identifier, workspace \\ "/tmp/nope") do
    %{
      identifier: identifier,
      worker_host: nil,
      workspace_path: workspace
    }
  end

  defp rejected_outcome do
    %{
      status: :rejected,
      steps: [],
      recipe: nil,
      rejection: %{reason: "unit-tests-only", missing_coverage: "no HTTP call"},
      skipped_reason: nil,
      started_at: DateTime.utc_now(),
      finished_at: DateTime.utc_now()
    }
  end

  describe "apply_verification_outcome :rejected" do
    test "first rejection schedules a retry and bumps the rejection counter" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        verification_enabled: true,
        tracker_active_states: ["Todo", "In Progress"]
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue_id = "issue-reject-1"
      identifier = "OPAL-2001"
      state = base_state(issue_id, identifier)

      updated =
        Orchestrator.apply_verification_outcome_for_test(
          state,
          issue_id,
          entry(identifier),
          :rejected,
          rejected_outcome()
        )

      assert Map.get(updated.critic_rejection_attempts, issue_id) == 1
      # Issue reverted to last active state so it will be re-picked.
      assert_receive {:memory_tracker_state_update, ^issue_id, "In Progress"}, 1_000
      # Retry scheduled so the issue gets another crack.
      assert Map.has_key?(updated.retry_attempts, issue_id)
    end

    test "third rejection (cap=2) falls through to :fail handling" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        verification_enabled: true,
        tracker_active_states: ["Todo", "In Progress"]
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue_id = "issue-reject-cap"
      identifier = "OPAL-2002"

      state =
        base_state(issue_id, identifier)
        # Seed with 1 prior rejection so this becomes the 2nd — equals cap.
        |> Map.put(:critic_rejection_attempts, %{issue_id => 1})

      assert Config.settings!().verification.critic_max_rejections == 2

      updated =
        Orchestrator.apply_verification_outcome_for_test(
          state,
          issue_id,
          entry(identifier),
          :rejected,
          rejected_outcome()
        )

      # Counter cleared on fall-through; :fail path schedules its own retry.
      refute Map.has_key?(updated.critic_rejection_attempts, issue_id)
      assert Map.has_key?(updated.retry_attempts, issue_id)
      # :fail path reverts tracker state too.
      assert_receive {:memory_tracker_state_update, ^issue_id, "In Progress"}, 1_000
    end

    test "configurable cap — critic_max_rejections=5 lets the 4th rejection retry" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        verification_enabled: true,
        verification_critic_max_rejections: 5,
        tracker_active_states: ["Todo", "In Progress"]
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue_id = "issue-reject-big-cap"
      identifier = "OPAL-2003"

      state =
        base_state(issue_id, identifier)
        |> Map.put(:critic_rejection_attempts, %{issue_id => 3})

      updated =
        Orchestrator.apply_verification_outcome_for_test(
          state,
          issue_id,
          entry(identifier),
          :rejected,
          rejected_outcome()
        )

      # Under the cap → retry path, counter bumped to 4.
      assert Map.get(updated.critic_rejection_attempts, issue_id) == 4
    end

    test ":pass after a prior rejection clears the counter" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        verification_enabled: true
      )

      issue_id = "issue-eventually-passes"
      identifier = "OPAL-2004"

      state =
        base_state(issue_id, identifier)
        |> Map.put(:critic_rejection_attempts, %{issue_id => 1})

      pass_outcome = %{
        status: :pass,
        steps: [],
        recipe: nil,
        rejection: nil,
        skipped_reason: nil,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now()
      }

      updated =
        Orchestrator.apply_verification_outcome_for_test(
          state,
          issue_id,
          entry(identifier),
          :pass,
          pass_outcome
        )

      refute Map.has_key?(updated.critic_rejection_attempts, issue_id)
      assert MapSet.member?(updated.completed, issue_id)
    end
  end

  describe "build_verify_settings" do
    test "critic disabled does not shell out (returns the settings unchanged)" do
      settings = %VerificationSettings{
        enabled: true,
        required: false,
        step_timeout_ms: 1_000,
        critic_enabled: false
      }

      result =
        Orchestrator.build_verify_settings_for_test(
          settings,
          %{identifier: "X", issue_title: "T", issue_description: "D"},
          "/tmp/ws"
        )

      refute Map.has_key?(result, :task_summary)
      refute Map.has_key?(result, :diff)
    end

    test "critic enabled derives task_summary from issue metadata" do
      settings = %VerificationSettings{
        enabled: true,
        required: false,
        step_timeout_ms: 1_000,
        critic_enabled: true
      }

      # /tmp is a safe cwd for git-not-a-repo — merge_base will fail and we
      # collapse diff to "". task_summary is the important assertion here.
      result =
        Orchestrator.build_verify_settings_for_test(
          settings,
          %{identifier: "X", issue_title: "Add JSON", issue_description: "body"},
          "/tmp"
        )

      assert result.task_summary == "Add JSON\n\nbody"
      assert is_binary(result.diff)
    end
  end
end
