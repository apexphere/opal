defmodule SymphonyElixir.Wiki.Injector do
  @moduledoc """
  Retrieval-aware injection of wiki entries into a workspace.

  At workspace creation, asks `Wiki.query/3` for the top-K entries relevant
  to the issue, then copies each as `<workspace>/.claude/wiki/<slug>.md`.

  Hard caps:
    * Total injected bytes ≤ 20 KB. Lower-priority entries (later in the
      query result) are dropped first.
    * If `Wiki.query/3` errors or times out, log a warning and inject
      nothing — workspace creation must never block on this.
  """

  require Logger

  alias SymphonyElixir.Wiki
  alias SymphonyElixir.Wiki.Store

  @injected_subdir ".claude/wiki"
  @max_total_bytes 20 * 1024
  @default_top_k 5

  @doc "Returns the relative subdirectory under the workspace where wiki entries land."
  @spec injected_subdir() :: String.t()
  def injected_subdir, do: @injected_subdir

  @doc """
  Performs the injection. `issue_context` is the same shape produced by
  `Workspace`'s issue-context normalizer (`%{issue_id, issue_identifier, ...}`)
  but may include `:title` and `:body` for richer queries.

  Returns `:ok` regardless of inner errors — this is best-effort and never
  blocks workspace creation.
  """
  @spec inject(Path.t(), String.t(), map()) :: :ok
  def inject(workspace, project_key, issue_context)
      when is_binary(workspace) and is_binary(project_key) and is_map(issue_context) do
    case Wiki.query(project_key, issue_context, limit: @default_top_k) do
      {:ok, slugs} ->
        copy_entries(workspace, project_key, slugs)

      {:error, reason} ->
        Logger.warning("Wiki query failed; skipping injection workspace=#{workspace} project_key=#{project_key} reason=#{inspect(reason)}")

        :ok
    end
  rescue
    error ->
      Logger.warning("Wiki injection raised; skipping workspace=#{workspace} project_key=#{project_key} error=#{Exception.message(error)}")

      :ok
  end

  defp copy_entries(workspace, project_key, slugs) do
    target_dir = Path.join(workspace, @injected_subdir)
    File.mkdir_p!(target_dir)

    {written, _bytes} =
      slugs
      |> Enum.reduce({[], 0}, fn slug, {acc, bytes} ->
        case load_entry_raw(project_key, slug) do
          {:ok, raw} when bytes + byte_size(raw) <= @max_total_bytes ->
            target = Path.join(target_dir, slug <> ".md")
            File.write!(target, raw)
            {[slug | acc], bytes + byte_size(raw)}

          {:ok, _raw} ->
            {acc, bytes}

          {:error, _reason} ->
            {acc, bytes}
        end
      end)

    Logger.debug("Wiki injection wrote #{length(written)} entries workspace=#{workspace} project_key=#{project_key}")

    :ok
  end

  defp load_entry_raw(project_key, slug) do
    path = Store.entry_path(Wiki.root!(), project_key, slug)

    case File.read(path) do
      {:ok, raw} -> {:ok, raw}
      error -> error
    end
  end
end
