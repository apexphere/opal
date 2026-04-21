defmodule SymphonyElixir.Verification.CriticContext do
  @moduledoc """
  Derives the context the critic needs to judge a verification recipe —
  a `task_summary` (what the change is supposed to deliver) and a `diff`
  (what actually changed, relative to the branch point).

  The derivation shells out to `git` inside the workspace. Both calls are
  defensive: any failure collapses to an empty string so the critic can
  still judge on the recipe alone. Both payloads are bounded in size so a
  huge diff or essay-length issue body doesn't blow the prompt budget:
  * `task_summary` — trimmed, then tail-truncated to ~4 KB.
  * `diff` — 20 KB cap with a head/tail split when over budget so the
    critic sees both ends of the change.

  The git seam is injected via `git_module` so tests can return canned
  diffs without actually shelling out.
  """

  @default_git_module SymphonyElixir.Verification.CriticContext.Git

  @task_summary_limit 4_000
  @diff_limit 20_000
  @diff_head_tail 10_000

  @type issue_like :: %{
          optional(:title) => String.t() | nil,
          optional(:description) => String.t() | nil
        }

  @type t :: %{task_summary: String.t(), diff: String.t()}

  @spec derive(issue_like() | nil, Path.t() | nil, keyword()) :: t()
  def derive(issue, workspace_path, opts \\ []) do
    %{
      task_summary: build_task_summary(issue),
      diff: build_diff(workspace_path, opts)
    }
  end

  @doc false
  @spec task_summary_limit() :: pos_integer()
  def task_summary_limit, do: @task_summary_limit

  @doc false
  @spec diff_limit() :: pos_integer()
  def diff_limit, do: @diff_limit

  defp build_task_summary(nil), do: ""

  defp build_task_summary(issue) do
    title = issue |> Map.get(:title) |> to_trimmed_string()
    body = issue |> Map.get(:description) |> to_trimmed_string()

    merged =
      case {title, body} do
        {"", ""} -> ""
        {t, ""} -> t
        {"", b} -> b
        {t, b} -> t <> "\n\n" <> b
      end

    truncate(merged, @task_summary_limit)
  end

  defp build_diff(nil, _opts), do: ""

  defp build_diff(workspace_path, opts) when is_binary(workspace_path) do
    git = Keyword.get(opts, :git_module, @default_git_module)

    case git.merge_base(workspace_path) do
      {:ok, base} ->
        case git.diff(workspace_path, base) do
          {:ok, diff} -> truncate_diff(diff)
          {:error, _} -> ""
        end

      {:error, _} ->
        ""
    end
  end

  defp to_trimmed_string(nil), do: ""
  defp to_trimmed_string(value) when is_binary(value), do: String.trim(value)

  defp truncate(string, limit) when byte_size(string) <= limit, do: string

  defp truncate(string, limit) do
    kept = binary_part(string, 0, limit)
    kept <> "\n…"
  end

  defp truncate_diff(diff) when byte_size(diff) <= @diff_limit, do: diff

  defp truncate_diff(diff) do
    total = byte_size(diff)
    omitted = total - 2 * @diff_head_tail
    head = binary_part(diff, 0, @diff_head_tail)
    tail = binary_part(diff, total - @diff_head_tail, @diff_head_tail)
    head <> "\n… [truncated #{omitted} bytes] …\n" <> tail
  end
end
