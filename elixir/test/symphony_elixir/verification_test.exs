defmodule SymphonyElixir.VerificationTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Verification

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "opal-verification-ws-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)

    on_exit(fn ->
      File.rm_rf(workspace)
      Application.delete_env(:symphony_elixir, :verification_executor_module)
    end)

    %{workspace: workspace}
  end

  defp settings(opts \\ []) do
    base = %{
      enabled: true,
      required: Keyword.get(opts, :required, false),
      step_timeout_ms: Keyword.get(opts, :step_timeout_ms, 5_000)
    }

    Enum.reduce(
      [:critic_enabled, :critic_timeout_ms, :task_summary, :diff, :critic_fun, :issue_id, :identifier],
      base,
      fn key, acc ->
        case Keyword.fetch(opts, key) do
          {:ok, value} -> Map.put(acc, key, value)
          :error -> acc
        end
      end
    )
  end

  defp write_recipe!(workspace, steps, description \\ nil) do
    File.mkdir_p!(Path.join(workspace, ".opal"))

    payload =
      %{"steps" => steps}
      |> then(fn p -> if description, do: Map.put(p, "description", description), else: p end)

    File.write!(Path.join(workspace, ".opal/verify.json"), Jason.encode!(payload))
  end

  test "passes when every step's exit matches expect_exit", %{workspace: workspace} do
    write_recipe!(workspace, [%{"name" => "ok-step", "shell" => "true"}])

    outcome = Verification.verify(workspace, settings())

    assert outcome.status == :pass
    assert [%{name: "ok-step", passed: true, exit: 0}] = outcome.steps
    assert File.exists?(Path.join(workspace, ".opal/verify-log.json"))
  end

  test "fails on the first non-matching exit and stops executing further steps",
       %{workspace: workspace} do
    write_recipe!(workspace, [
      %{"name" => "first-fails", "shell" => "exit 7"},
      %{"name" => "should-not-run", "shell" => "echo nope"}
    ])

    outcome = Verification.verify(workspace, settings())

    assert outcome.status == :fail
    assert [%{name: "first-fails", passed: false, exit: 7}] = outcome.steps
  end

  test "honours expect_exit when the step is supposed to exit non-zero",
       %{workspace: workspace} do
    write_recipe!(workspace, [
      %{"name" => "expect-1", "shell" => "exit 1", "expect_exit" => 1}
    ])

    assert %{status: :pass} = Verification.verify(workspace, settings())
  end

  test "skips with :no_recipe when no recipe file is present and required=false",
       %{workspace: workspace} do
    outcome = Verification.verify(workspace, settings(required: false))

    assert outcome.status == :skipped
    assert outcome.skipped_reason == :no_recipe
  end

  test "fails with :no_recipe when no recipe file is present and required=true",
       %{workspace: workspace} do
    outcome = Verification.verify(workspace, settings(required: true))

    assert outcome.status == :fail
    assert outcome.skipped_reason == :no_recipe
  end

  test "fails when the recipe file is malformed", %{workspace: workspace} do
    File.mkdir_p!(Path.join(workspace, ".opal"))
    File.write!(Path.join(workspace, ".opal/verify.json"), "not json")

    outcome = Verification.verify(workspace, settings())

    assert outcome.status == :fail
    assert {:invalid_recipe, _} = outcome.skipped_reason
  end

  test "persists a JSON log capturing every step", %{workspace: workspace} do
    write_recipe!(workspace, [%{"name" => "echo", "shell" => "echo hello"}])

    Verification.verify(workspace, settings())

    log = File.read!(Path.join(workspace, ".opal/verify-log.json")) |> Jason.decode!()
    assert log["status"] == "pass"
    assert [%{"name" => "echo", "output" => output, "passed" => true}] = log["steps"]
    assert output =~ "hello"
  end

  test "log_rel_path points at .opal/verify-log.json" do
    assert Verification.log_rel_path() == ".opal/verify-log.json"
  end

  test "swallows persist-log failures so verification still returns an outcome",
       %{workspace: workspace} do
    File.write!(Path.join(workspace, ".opal"), "")

    outcome = Verification.verify(workspace, settings())

    assert outcome.status == :fail
    assert {:invalid_recipe, {:read_failed, _}} = outcome.skipped_reason
    refute File.exists?(Path.join(workspace, ".opal/verify-log.json"))
  end

  test "uses a pluggable executor when configured", %{workspace: workspace} do
    defmodule FakeExecutor do
      @behaviour SymphonyElixir.Verification.Executor

      alias SymphonyElixir.Verification.Recipe.Step

      @impl true
      def run_step(%Step{} = step, _workspace, _opts) do
        send(self(), {:fake_executed, step.name})
        %{exit: step.expect_exit, output: "fake-output", duration_ms: 1}
      end
    end

    Application.put_env(:symphony_elixir, :verification_executor_module, FakeExecutor)
    write_recipe!(workspace, [%{"name" => "via-fake", "shell" => "ignored"}])

    outcome = Verification.verify(workspace, settings())

    assert outcome.status == :pass
    assert [%{name: "via-fake", output: "fake-output"}] = outcome.steps
    assert_received {:fake_executed, "via-fake"}
  end

  test "bash executor records :timeout exit when step exceeds timeout", %{workspace: workspace} do
    write_recipe!(workspace, [%{"name" => "slow", "shell" => "sleep 2"}])

    outcome = Verification.verify(workspace, settings(step_timeout_ms: 50))

    assert outcome.status == :fail
    assert [%{name: "slow", passed: false, exit: :timeout}] = outcome.steps

    log = Path.join(workspace, ".opal/verify-log.json") |> File.read!() |> Jason.decode!()
    assert [%{"exit" => "timeout"}] = log["steps"]
  end

  describe "critic gate" do
    import ExUnit.CaptureLog

    test "critic disabled (default) does not invoke the critic", %{workspace: workspace} do
      write_recipe!(workspace, [%{"name" => "ok", "shell" => "true"}])
      test_pid = self()

      critic_fun = fn _, _, _, _ ->
        send(test_pid, :critic_called)
        {:ok, :approve}
      end

      # critic_enabled defaults off — critic_fun should be ignored.
      outcome = Verification.verify(workspace, settings(critic_fun: critic_fun))

      assert outcome.status == :pass
      refute_received :critic_called
    end

    test "critic enabled + approve allows recipe to execute", %{workspace: workspace} do
      write_recipe!(workspace, [%{"name" => "ok", "shell" => "true"}])
      test_pid = self()

      critic_fun = fn task_summary, diff, recipe_json, _opts ->
        send(test_pid, {:critic_called, task_summary, diff, recipe_json})
        {:ok, :approve}
      end

      log =
        capture_log(fn ->
          outcome =
            Verification.verify(
              workspace,
              settings(
                critic_enabled: true,
                critic_fun: critic_fun,
                task_summary: "Add --json flag",
                diff: "+ new line",
                issue_id: "gh:42",
                identifier: "#42"
              )
            )

          assert outcome.status == :pass
          assert outcome.rejection == nil
        end)

      assert log =~ "Verification critic approved recipe"
      assert log =~ "issue_id=gh:42"
      assert log =~ "identifier=#42"

      assert_received {:critic_called, "Add --json flag", "+ new line", recipe_json}
      # Recipe body should be serialized JSON the critic can read.
      decoded = Jason.decode!(recipe_json)
      assert [%{"name" => "ok", "shell" => "true"}] = decoded["steps"]
    end

    test "critic enabled + reject short-circuits and returns :rejected", %{workspace: workspace} do
      write_recipe!(workspace, [
        %{"name" => "should-never-run", "shell" => "echo NOPE && exit 1"}
      ])

      critic_fun = fn _, _, _, _ ->
        {:ok, {:reject, %{reason: "unit-tests-only", missing_coverage: "no HTTP call"}}}
      end

      {outcome, captured} =
        with_log(fn ->
          Verification.verify(
            workspace,
            settings(critic_enabled: true, critic_fun: critic_fun)
          )
        end)

      assert outcome.status == :rejected
      assert outcome.rejection == %{reason: "unit-tests-only", missing_coverage: "no HTTP call"}
      assert outcome.steps == []

      assert captured =~ "Verification critic rejected recipe"
      assert captured =~ "unit-tests-only"
      assert captured =~ "no HTTP call"

      persisted = Path.join(workspace, ".opal/verify-log.json") |> File.read!() |> Jason.decode!()
      assert persisted["status"] == "rejected"

      assert persisted["rejection"] == %{
               "reason" => "unit-tests-only",
               "missing_coverage" => "no HTTP call"
             }

      assert persisted["steps"] == []
    end

    test "critic error falls open to recipe execution with a warning", %{workspace: workspace} do
      write_recipe!(workspace, [%{"name" => "ok", "shell" => "true"}])

      critic_fun = fn _, _, _, _ ->
        {:error, {:codex_command_not_found, "codex"}}
      end

      log =
        capture_log(fn ->
          outcome =
            Verification.verify(
              workspace,
              settings(
                critic_enabled: true,
                critic_fun: critic_fun,
                issue_id: "gh:99",
                identifier: "#99"
              )
            )

          assert outcome.status == :pass
        end)

      assert log =~ "Verification critic failed"
      assert log =~ "codex_command_not_found"
      assert log =~ "issue_id=gh:99"
      assert log =~ "identifier=#99"
    end

    test "critic crash via raise falls open", %{workspace: workspace} do
      write_recipe!(workspace, [%{"name" => "ok", "shell" => "true"}])

      critic_fun = fn _, _, _, _ ->
        raise "boom"
      end

      log =
        capture_log(fn ->
          outcome =
            Verification.verify(
              workspace,
              settings(critic_enabled: true, critic_fun: critic_fun)
            )

          assert outcome.status == :pass
        end)

      assert log =~ "Verification critic failed"
      assert log =~ "critic_crashed"
    end

    test "critic crash via throw/exit falls open", %{workspace: workspace} do
      # Exercises the `catch kind, reason` branch (non-exception exits).
      write_recipe!(workspace, [%{"name" => "ok", "shell" => "true"}])

      critic_fun = fn _, _, _, _ ->
        throw(:weird_signal)
      end

      log =
        capture_log(fn ->
          outcome =
            Verification.verify(
              workspace,
              settings(critic_enabled: true, critic_fun: critic_fun)
            )

          assert outcome.status == :pass
        end)

      assert log =~ "Verification critic failed"
      assert log =~ "critic_crashed"
      assert log =~ "weird_signal"
    end

    test "critic timeout falls open", %{workspace: workspace} do
      write_recipe!(workspace, [%{"name" => "ok", "shell" => "true"}])

      critic_fun = fn _, _, _, _ ->
        Process.sleep(500)
        {:ok, :approve}
      end

      log =
        capture_log(fn ->
          outcome =
            Verification.verify(
              workspace,
              settings(
                critic_enabled: true,
                critic_fun: critic_fun,
                critic_timeout_ms: 50
              )
            )

          assert outcome.status == :pass
        end)

      assert log =~ "Verification critic timed out"
    end

    test "rejected outcome is not executed — executor never invoked", %{workspace: workspace} do
      # Use the pluggable executor to prove it never runs.
      defmodule NeverCalledExecutor do
        @behaviour SymphonyElixir.Verification.Executor
        @impl true
        def run_step(_step, _workspace, _opts) do
          send(self(), :executor_ran)
          %{exit: 0, output: "", duration_ms: 1}
        end
      end

      Application.put_env(:symphony_elixir, :verification_executor_module, NeverCalledExecutor)
      write_recipe!(workspace, [%{"name" => "unused", "shell" => "true"}])

      critic_fun = fn _, _, _, _ ->
        {:ok, {:reject, %{reason: "r", missing_coverage: "m"}}}
      end

      outcome =
        Verification.verify(
          workspace,
          settings(critic_enabled: true, critic_fun: critic_fun)
        )

      assert outcome.status == :rejected
      refute_received :executor_ran
    end
  end
end
