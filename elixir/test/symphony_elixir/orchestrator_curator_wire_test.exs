defmodule SymphonyElixir.OrchestratorCuratorWireTest do
  @moduledoc """
  Exercises the orchestrator's wiring into Curator.Queue on verification
  `:fail`. We don't need to reach the LLM — we stub the Curator.Queue name
  to capture the cast payload and verify the payload shape + gating flag.
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Curator.Queue, as: CuratorQueue

  setup do
    previous_flag = Application.get_env(:symphony_elixir, :curator_auto_learn_from_failures)
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)

    # Swap the real Queue out so we can observe casts synchronously. We
    # register a proxy under the CuratorQueue name that forwards casts to
    # `self()` as a message.
    real_queue_pid = Process.whereis(CuratorQueue)
    if real_queue_pid, do: Process.unregister(CuratorQueue)

    test_pid = self()

    proxy_pid =
      spawn_link(fn ->
        Stream.repeatedly(fn ->
          receive do
            {:"$gen_cast", {:failure, payload, opts}} ->
              send(test_pid, {:captured_failure, payload, opts})
          end
        end)
        |> Stream.run()
      end)

    Process.register(proxy_pid, CuratorQueue)

    on_exit(fn ->
      if Process.alive?(proxy_pid), do: Process.exit(proxy_pid, :kill)
      if Process.whereis(CuratorQueue), do: Process.unregister(CuratorQueue)
      if real_queue_pid, do: Process.register(real_queue_pid, CuratorQueue)

      case previous_flag do
        nil -> Application.delete_env(:symphony_elixir, :curator_auto_learn_from_failures)
        v -> Application.put_env(:symphony_elixir, :curator_auto_learn_from_failures, v)
      end

      case previous_memory_issues do
        nil -> Application.delete_env(:symphony_elixir, :memory_tracker_issues)
        v -> Application.put_env(:symphony_elixir, :memory_tracker_issues, v)
      end
    end)

    :ok
  end

  defp failing_outcome(_identifier) do
    %{
      status: :fail,
      steps: [
        %{
          name: "ok",
          shell: "true",
          expect_exit: 0,
          exit: 0,
          passed: true,
          output: "",
          duration_ms: 1
        },
        %{
          name: "boom",
          shell: "false",
          expect_exit: 0,
          exit: 1,
          passed: false,
          output: "err\n",
          duration_ms: 2
        }
      ],
      skipped_reason: nil,
      recipe: %SymphonyElixir.Verification.Recipe{
        description: "test recipe",
        steps: [
          %SymphonyElixir.Verification.Recipe.Step{
            name: "boom",
            shell: "false",
            expect_exit: 0
          }
        ]
      },
      started_at: ~U[2026-04-20 00:00:00Z],
      finished_at: ~U[2026-04-20 00:00:05Z]
    }
  end

  defp orchestrator_with_verifying_entry(tag, issue_id, identifier) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: System.tmp_dir!(),
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Closed"]
    )

    orchestrator_name = Module.concat(__MODULE__, tag)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    :sys.replace_state(pid, fn state ->
      state
      |> Map.put(:verifying, %{
        issue_id => %{
          pid: self(),
          ref: nil,
          identifier: identifier,
          worker_host: nil,
          workspace_path: "/tmp/nonexistent"
        }
      })
      |> Map.put(:claimed, MapSet.new([issue_id]))
    end)

    pid
  end

  test "casts the failure payload to Curator.Queue when auto-learn is on" do
    Application.put_env(:symphony_elixir, :curator_auto_learn_from_failures, true)

    issue_id = "issue-curator-1"
    identifier = "OPAL-2001"
    pid = orchestrator_with_verifying_entry(:CastsOn, issue_id, identifier)

    send(pid, {:verification_done, issue_id, failing_outcome(identifier)})

    assert_receive {:captured_failure, payload, _opts}, 1_000
    assert payload.issue_ref == identifier
    assert payload.failed_step.name == "boom"
    assert payload.output == "err\n"
    assert payload.started_at == "2026-04-20T00:00:00Z"
    assert %SymphonyElixir.Verification.Recipe{} = payload.recipe
  end

  test "skips the cast when the auto-learn flag is disabled" do
    Application.put_env(:symphony_elixir, :curator_auto_learn_from_failures, false)

    issue_id = "issue-curator-2"
    identifier = "OPAL-2002"
    pid = orchestrator_with_verifying_entry(:CastsOff, issue_id, identifier)

    send(pid, {:verification_done, issue_id, failing_outcome(identifier)})

    refute_receive {:captured_failure, _, _}, 200
  end

  test "skips the cast when the outcome has no recipe (e.g. :no_recipe fail)" do
    Application.put_env(:symphony_elixir, :curator_auto_learn_from_failures, true)

    issue_id = "issue-curator-3"
    identifier = "OPAL-2003"
    pid = orchestrator_with_verifying_entry(:NoRecipe, issue_id, identifier)

    outcome = %{
      failing_outcome(identifier)
      | recipe: nil,
        steps: []
    }

    send(pid, {:verification_done, issue_id, outcome})

    refute_receive {:captured_failure, _, _}, 200
  end

  test "skips the cast when all steps passed (defensive)" do
    Application.put_env(:symphony_elixir, :curator_auto_learn_from_failures, true)

    issue_id = "issue-curator-4"
    identifier = "OPAL-2004"
    pid = orchestrator_with_verifying_entry(:AllPassed, issue_id, identifier)

    outcome = %{
      failing_outcome(identifier)
      | steps: [
          %{
            name: "only",
            shell: "true",
            expect_exit: 0,
            exit: 0,
            passed: true,
            output: "",
            duration_ms: 1
          }
        ]
    }

    send(pid, {:verification_done, issue_id, outcome})

    refute_receive {:captured_failure, _, _}, 200
  end

  test "does not cast on :skipped status" do
    Application.put_env(:symphony_elixir, :curator_auto_learn_from_failures, true)

    issue_id = "issue-curator-5"
    identifier = "OPAL-2005"
    pid = orchestrator_with_verifying_entry(:Skipped, issue_id, identifier)

    outcome = %{failing_outcome(identifier) | status: :skipped}

    send(pid, {:verification_done, issue_id, outcome})

    refute_receive {:captured_failure, _, _}, 200
  end

  test "uses issue_id as issue_ref when identifier is missing" do
    Application.put_env(:symphony_elixir, :curator_auto_learn_from_failures, true)

    issue_id = "issue-curator-6"
    identifier = "OPAL-2006"
    pid = orchestrator_with_verifying_entry(:NoIdent, issue_id, identifier)

    :sys.replace_state(pid, fn state ->
      Map.put(state, :verifying, %{
        issue_id => %{
          pid: self(),
          ref: nil,
          identifier: nil,
          worker_host: nil,
          workspace_path: "/tmp/nonexistent"
        }
      })
    end)

    send(pid, {:verification_done, issue_id, failing_outcome(identifier)})

    assert_receive {:captured_failure, payload, _opts}, 1_000
    assert payload.issue_ref == issue_id
  end
end
