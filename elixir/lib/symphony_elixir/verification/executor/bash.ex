defmodule SymphonyElixir.Verification.Executor.Bash do
  @moduledoc """
  Default `SymphonyElixir.Verification.Executor` — runs the step's `shell`
  via `bash -lc` with the workspace as cwd. stderr is folded into stdout for
  Phase-1 logging simplicity.
  """

  @behaviour SymphonyElixir.Verification.Executor

  alias SymphonyElixir.Verification.Recipe.Step

  @impl true
  @spec run_step(Step.t(), Path.t(), keyword()) ::
          SymphonyElixir.Verification.Executor.result()
  def run_step(%Step{shell: shell}, workspace, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 600_000)
    started_at = System.monotonic_time(:millisecond)

    task =
      Task.async(fn ->
        System.cmd("bash", ["-lc", shell],
          cd: workspace,
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, exit_code}} ->
        %{
          exit: exit_code,
          output: output,
          duration_ms: elapsed(started_at)
        }

      nil ->
        %{
          exit: :timeout,
          output: "",
          duration_ms: elapsed(started_at)
        }
    end
  end

  defp elapsed(started_at_ms) do
    System.monotonic_time(:millisecond) - started_at_ms
  end
end
