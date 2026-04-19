defmodule SymphonyElixir.Knowledge do
  @moduledoc """
  Opal's per-project experience-knowledge subsystem.

  Holds accumulated learnings (CLAUDE.md, skills, memory) per target project
  outside the target repo, and injects the active project's knowledge into an
  agent workspace before `claude -p` spawns.

  Contract with Claude Code's native loader:
  * `<workspace>/CLAUDE.md` imports `@.claude/opal-knowledge.md`.
  * `<workspace>/.claude/opal-knowledge.md` contains the project's CLAUDE.md body.
  * `<workspace>/.claude/skills/` and `<workspace>/.claude/memory/` mirror the
    project's knowledge tree.
  """

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Knowledge.Store

  @opal_knowledge_rel_path ".claude/opal-knowledge.md"
  @opal_knowledge_import "@.claude/opal-knowledge.md"

  @spec inject(Path.t(), String.t()) :: :ok | {:error, term()}
  def inject(workspace, project_key)
      when is_binary(workspace) and is_binary(project_key) do
    knowledge = Config.settings!().knowledge

    case store_module().load(knowledge.root, project_key) do
      {:ok, tree} ->
        inject_tree(workspace, tree)

      {:error, reason} = error ->
        Logger.warning("Knowledge load failed project_key=#{project_key} reason=#{inspect(reason)}")

        error
    end
  end

  @spec inject_tree(Path.t(), Store.tree()) :: :ok
  def inject_tree(workspace, %{files: files})
      when is_binary(workspace) and is_map(files) do
    Enum.each(files, fn {relative_path, content} ->
      case relative_path do
        "CLAUDE.md" ->
          write_workspace_file(workspace, @opal_knowledge_rel_path, content)
          ensure_claude_md_import(workspace)

        other ->
          write_workspace_file(workspace, Path.join(".claude", other), content)
      end
    end)

    :ok
  end

  @spec capture(String.t(), String.t(), binary()) :: :ok | {:error, term()}
  def capture(project_key, relative_path, content)
      when is_binary(project_key) and is_binary(relative_path) and is_binary(content) do
    knowledge = Config.settings!().knowledge
    store_module().write(knowledge.root, project_key, relative_path, content)
  end

  @spec load(String.t()) :: {:ok, Store.tree()} | {:error, term()}
  def load(project_key) when is_binary(project_key) do
    knowledge = Config.settings!().knowledge
    store_module().load(knowledge.root, project_key)
  end

  @spec project_key() :: String.t()
  def project_key do
    Config.settings!().tracker |> project_key_for()
  end

  @spec project_key_for(map() | struct()) :: String.t()
  def project_key_for(tracker) do
    kind = Map.get(tracker, :kind) || "unknown"

    raw_slug =
      case kind do
        "github" -> Map.get(tracker, :repo) || "unknown"
        "linear" -> Map.get(tracker, :project_slug) || "unknown"
        "memory" -> Map.get(tracker, :project_slug) || "default"
        _ -> "unknown"
      end

    kind <> "_" <> sanitize_slug(raw_slug)
  end

  defp sanitize_slug(slug) when is_binary(slug) do
    slug
    |> String.replace(~r/[^a-zA-Z0-9._-]/, "_")
    |> String.replace(~r/_+/, "_")
    |> String.trim("_")
  end

  defp write_workspace_file(workspace, relative_path, content) do
    target = Path.join(workspace, relative_path)
    File.mkdir_p!(Path.dirname(target))
    File.write!(target, content)
  end

  defp ensure_claude_md_import(workspace) do
    claude_md_path = Path.join(workspace, "CLAUDE.md")

    existing =
      case File.read(claude_md_path) do
        {:ok, content} -> content
        {:error, :enoent} -> ""
      end

    case String.contains?(existing, @opal_knowledge_import) do
      true ->
        :ok

      false ->
        joiner = if existing == "" or String.ends_with?(existing, "\n"), do: "", else: "\n"
        separator = if existing == "", do: "", else: "\n"

        File.write!(
          claude_md_path,
          existing <> joiner <> separator <> @opal_knowledge_import <> "\n"
        )

        :ok
    end
  end

  defp store_module do
    case Application.get_env(:symphony_elixir, :knowledge_store_module) do
      nil ->
        case Config.settings!().knowledge.backend do
          "filesystem" -> SymphonyElixir.Knowledge.Store.Filesystem
        end

      mod when is_atom(mod) ->
        mod
    end
  end
end
