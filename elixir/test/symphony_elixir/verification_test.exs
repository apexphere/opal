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
    %{
      enabled: true,
      required: Keyword.get(opts, :required, false),
      step_timeout_ms: Keyword.get(opts, :step_timeout_ms, 5_000)
    }
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
end
