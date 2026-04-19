defmodule SymphonyElixir.Verification do
  @moduledoc """
  Self-verification — exercise the build the way a user would, before
  treating an agent run as truly done.

  Phase 1 contract:
  * Recipe is read from `<workspace>/.opal/verify.json` (see
    `SymphonyElixir.Verification.Recipe`). The agent emits the recipe as a
    byproduct of building. Opal does not author it.
  * Each step is executed sequentially via the configured executor (default
    `Executor.Bash`). A step passes when its exit code matches `expect_exit`.
  * The full execution log is persisted to `<workspace>/.opal/verify-log.json`.
  * The result is `:pass`, `:fail`, or `:skipped` — Phase 1 has no
    re-prompting loop. Phase 2 will feed failure evidence into the next
    agent turn.

  Behaviour is gated by `config.verification.enabled`. When the flag is off
  this module is never called. When on but no recipe exists, behaviour
  depends on `config.verification.required`:
  * `required: false` (default) — skip with `:no_recipe` reason.
  * `required: true`           — fail.
  """

  require Logger

  alias SymphonyElixir.Verification.{Recipe, Result}

  @log_rel_path ".opal/verify-log.json"

  @type settings :: %{required(:required) => boolean(), required(:step_timeout_ms) => pos_integer()}
  @type status :: :pass | :fail | :skipped
  @type outcome :: %{
          status: status(),
          steps: [map()],
          skipped_reason: term() | nil,
          recipe: Recipe.t() | nil,
          started_at: DateTime.t(),
          finished_at: DateTime.t()
        }

  @spec verify(Path.t(), settings()) :: outcome()
  def verify(workspace, settings) when is_binary(workspace) and is_map(settings) do
    started_at = DateTime.utc_now()

    outcome =
      case Recipe.read(workspace) do
        {:ok, recipe} ->
          execute(recipe, workspace, settings, started_at)

        {:error, :no_recipe} when settings.required ->
          fail_outcome(:no_recipe, started_at)

        {:error, :no_recipe} ->
          skip_outcome(:no_recipe, started_at)

        {:error, {:invalid_recipe, _} = reason} ->
          fail_outcome(reason, started_at)
      end

    persist_log(workspace, outcome)
    outcome
  end

  @spec log_rel_path() :: String.t()
  def log_rel_path, do: @log_rel_path

  defp execute(%Recipe{steps: steps} = recipe, workspace, settings, started_at) do
    executor = executor_module()
    timeout_ms = settings.step_timeout_ms

    {step_results, status} =
      Enum.reduce_while(steps, {[], :pass}, fn step, {acc, _status} ->
        run = executor.run_step(step, workspace, timeout_ms: timeout_ms)
        passed = run.exit == step.expect_exit

        record =
          %{
            name: step.name,
            shell: step.shell,
            expect_exit: step.expect_exit,
            exit: run.exit,
            passed: passed,
            output: run.output,
            duration_ms: run.duration_ms
          }

        if passed do
          {:cont, {[record | acc], :pass}}
        else
          {:halt, {[record | acc], :fail}}
        end
      end)

    %{
      status: status,
      steps: Enum.reverse(step_results),
      skipped_reason: nil,
      recipe: recipe,
      started_at: started_at,
      finished_at: DateTime.utc_now()
    }
  end

  defp skip_outcome(reason, started_at) do
    %{
      status: :skipped,
      steps: [],
      skipped_reason: reason,
      recipe: nil,
      started_at: started_at,
      finished_at: DateTime.utc_now()
    }
  end

  defp fail_outcome(reason, started_at) do
    %{
      status: :fail,
      steps: [],
      skipped_reason: reason,
      recipe: nil,
      started_at: started_at,
      finished_at: DateTime.utc_now()
    }
  end

  defp persist_log(workspace, outcome) do
    log_path = Path.join(workspace, @log_rel_path)
    File.mkdir_p!(Path.dirname(log_path))
    File.write!(log_path, Result.encode(outcome))
  rescue
    error ->
      Logger.warning("Verification log persist failed workspace=#{workspace} reason=#{inspect(error)}")

      :ok
  end

  defp executor_module do
    Application.get_env(
      :symphony_elixir,
      :verification_executor_module,
      SymphonyElixir.Verification.Executor.Bash
    )
  end
end
