defmodule SymphonyElixir.Verification.CriticContext.Git do
  @moduledoc """
  Default git backend for `CriticContext.derive/3`. Shells out to the
  `git` binary inside the workspace. Non-zero exits surface as
  `{:error, {:git_exit, status, output}}` and the caller collapses to
  an empty string so missing `main`, uninitialised repos, missing
  workspace paths, or a missing `git` binary never block the critic.

  A test double can implement the two-callback contract (`merge_base/1`
  and `diff/2`) and be injected via `CriticContext.derive/3`'s
  `:git_module` option.
  """

  @callback merge_base(Path.t()) :: {:ok, String.t()} | {:error, term()}
  @callback diff(Path.t(), String.t()) :: {:ok, String.t()} | {:error, term()}

  @behaviour __MODULE__

  @impl true
  def merge_base(workspace_path) when is_binary(workspace_path) do
    case shell("merge-base", ["HEAD", "main"], workspace_path) do
      {:ok, output} ->
        {:ok, String.trim(output)}

      {:error, _} ->
        case shell("merge-base", ["HEAD", "origin/main"], workspace_path) do
          {:ok, output} -> {:ok, String.trim(output)}
          {:error, _} = err -> err
        end
    end
  end

  @impl true
  def diff(workspace_path, base) when is_binary(workspace_path) and is_binary(base) do
    shell("diff", [base <> "...HEAD"], workspace_path)
  end

  defp shell(subcommand, args, cwd) do
    case System.cmd("git", [subcommand | args], cd: cwd, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:git_exit, status, output}}
    end
  end
end
