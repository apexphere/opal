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
  * The result is `:pass`, `:fail`, `:skipped`, or `:rejected`. `:rejected`
    is produced by the optional critic gate (see below) when the recipe is
    judged not to exercise the user-visible behaviour the diff introduces.

  Critic gate (default off):
  * When `settings.critic_enabled` is true, an independent-runtime critic
    (`SymphonyElixir.Verification.Critic`) is invoked between reading the
    recipe and executing it. On `:approve`, execution proceeds. On
    `{:reject, %{reason, missing_coverage}}`, execution is short-circuited
    and an outcome with `status: :rejected` is returned. On critic error
    (codex missing, timeout, decode error) the call **fails open**: a
    warning is logged and execution proceeds as if the critic were
    disabled. This avoids blocking delivery on critic flakes.
  * Timeout is enforced at the caller via `Task.async` + `Task.yield` —
    `System.cmd/3` itself has no timeout.

  Behaviour is gated by `settings.enabled`. When the flag is off this
  module is never called. When on but no recipe exists, behaviour depends
  on `settings.required`:
  * `required: false` (default) — skip with `:no_recipe` reason.
  * `required: true`           — fail.
  """

  require Logger

  alias SymphonyElixir.Verification.{Critic, Recipe, Result}

  @log_rel_path ".opal/verify-log.json"
  @default_critic_timeout_ms 180_000

  @type rejection :: %{reason: String.t(), missing_coverage: String.t()}
  @type status :: :pass | :fail | :skipped | :rejected
  @type settings :: %{
          optional(:critic_enabled) => boolean(),
          optional(:critic_timeout_ms) => pos_integer(),
          optional(:task_summary) => String.t(),
          optional(:diff) => String.t(),
          optional(:critic_fun) => (String.t(), String.t(), String.t(), keyword() ->
                                      {:ok, Critic.verdict()} | {:error, term()}),
          required(:required) => boolean(),
          required(:step_timeout_ms) => pos_integer()
        }
  @type outcome :: %{
          status: status(),
          steps: [map()],
          skipped_reason: term() | nil,
          recipe: Recipe.t() | nil,
          rejection: rejection() | nil,
          started_at: DateTime.t(),
          finished_at: DateTime.t()
        }

  @spec verify(Path.t(), settings()) :: outcome()
  def verify(workspace, settings) when is_binary(workspace) and is_map(settings) do
    started_at = DateTime.utc_now()

    outcome =
      case Recipe.read(workspace) do
        {:ok, recipe} ->
          gated_execute(recipe, workspace, settings, started_at)

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

  defp gated_execute(%Recipe{} = recipe, workspace, settings, started_at) do
    case maybe_critique(recipe, settings) do
      :approve ->
        execute(recipe, workspace, settings, started_at)

      {:reject, rejection} ->
        reject_outcome(recipe, rejection, started_at)
    end
  end

  defp maybe_critique(%Recipe{} = recipe, %{critic_enabled: true} = settings) do
    task_summary = Map.get(settings, :task_summary, "")
    diff = Map.get(settings, :diff, "")
    recipe_json = serialize_recipe(recipe)

    case run_critic(task_summary, diff, recipe_json, settings) do
      {:ok, :approve} ->
        :approve

      {:ok, {:reject, %{reason: _, missing_coverage: _} = rejection}} ->
        {:reject, rejection}

      {:error, reason} ->
        Logger.warning("Verification critic failed (fail-open): #{inspect(reason)}")

        :approve

      :timeout ->
        Logger.warning("Verification critic timed out (fail-open)")
        :approve
    end
  end

  defp maybe_critique(_recipe, _settings), do: :approve

  defp serialize_recipe(%Recipe{description: description, steps: steps}) do
    %{
      "description" => description,
      "steps" =>
        Enum.map(steps, fn step ->
          %{
            "name" => step.name,
            "shell" => step.shell,
            "expect_exit" => step.expect_exit
          }
        end)
    }
    |> Jason.encode!()
  end

  defp run_critic(task_summary, diff, recipe_json, settings) do
    critic_fun = Map.get(settings, :critic_fun) || (&Critic.critique/4)
    timeout_ms = Map.get(settings, :critic_timeout_ms, @default_critic_timeout_ms)

    parent = self()
    ref = make_ref()

    # Spawn an unlinked process. A try/rescue inside converts any crash —
    # raise, throw, or exit — into a tagged `:error` tuple so exits never
    # escape this boundary. The parent only ever receives the `{ref, result}`
    # message or hits the timeout.
    {pid, monitor_ref} =
      spawn_monitor(fn ->
        result =
          try do
            critic_fun.(task_summary, diff, recipe_json, [])
          rescue
            error -> {:error, {:critic_crashed, Exception.message(error)}}
          catch
            kind, reason -> {:error, {:critic_crashed, {kind, reason}}}
          end

        send(parent, {ref, result})
      end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result
    after
      timeout_ms ->
        Process.demonitor(monitor_ref, [:flush])
        Process.exit(pid, :kill)
        :timeout
    end
  end

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
      rejection: nil,
      started_at: started_at,
      finished_at: DateTime.utc_now()
    }
  end

  defp reject_outcome(%Recipe{} = recipe, rejection, started_at) do
    %{
      status: :rejected,
      steps: [],
      skipped_reason: nil,
      recipe: recipe,
      rejection: rejection,
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
      rejection: nil,
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
      rejection: nil,
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
