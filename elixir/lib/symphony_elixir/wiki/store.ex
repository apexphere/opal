defmodule SymphonyElixir.Wiki.Store do
  @moduledoc """
  Filesystem layout for wiki entries.

  Layout: `<knowledge_root>/<project_key>/wiki/<slug>.md`.

  Lives under the same `knowledge.root` config as `Knowledge.Store` but is
  intentionally a separate module so wiki can later move to git/SQLite
  without touching the experience-knowledge subsystem.
  """

  alias SymphonyElixir.Wiki.Entry

  @wiki_subdir "wiki"
  @entry_extension ".md"

  @doc "Returns the absolute directory holding entries for a project."
  @spec dir(Path.t(), String.t()) :: Path.t()
  def dir(root, project_key) when is_binary(root) and is_binary(project_key) do
    Path.join([root, project_key, @wiki_subdir])
  end

  @doc "Returns the absolute file path for `slug` under `project_key`."
  @spec entry_path(Path.t(), String.t(), String.t()) :: Path.t()
  def entry_path(root, project_key, slug) when is_binary(slug) do
    Path.join(dir(root, project_key), slug <> @entry_extension)
  end

  @doc """
  Lists all slugs in the project's wiki, sorted.
  Returns `{:ok, [slug]}` even when the directory does not exist (auto-create
  contract — same as `Knowledge.Store.Filesystem.load/2`).
  """
  @spec list_slugs(Path.t(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_slugs(root, project_key) do
    target = dir(root, project_key)

    case File.ls(target) do
      {:ok, entries} ->
        slugs =
          entries
          |> Enum.filter(&String.ends_with?(&1, @entry_extension))
          |> Enum.map(&String.replace_suffix(&1, @entry_extension, ""))
          |> Enum.sort()

        {:ok, slugs}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Reads and parses an entry by slug."
  @spec get(Path.t(), String.t(), String.t()) :: {:ok, Entry.t()} | {:error, term()}
  def get(root, project_key, slug) do
    case File.read(entry_path(root, project_key, slug)) do
      {:ok, raw} -> Entry.parse(raw)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Writes an entry atomically: write to a sibling `.tmp` file then rename.
  Creates parent directories if needed.
  """
  @spec put(Path.t(), String.t(), Entry.t()) :: :ok | {:error, term()}
  def put(root, project_key, %Entry{} = entry) do
    with :ok <- validate_slug(entry.slug) do
      target = entry_path(root, project_key, entry.slug)
      File.mkdir_p!(Path.dirname(target))

      tmp = target <> ".tmp"
      File.write!(tmp, Entry.serialize(entry))
      File.rename!(tmp, target)

      :ok
    end
  end

  @doc "Deletes an entry by slug. Returns `:ok` even if the file is absent."
  @spec delete(Path.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def delete(root, project_key, slug) do
    case File.rm(entry_path(root, project_key, slug)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_slug(slug) when is_binary(slug) do
    cond do
      slug == "" -> {:error, :empty_slug}
      String.contains?(slug, "/") -> {:error, {:unsafe_slug, slug}}
      String.contains?(slug, "..") -> {:error, {:unsafe_slug, slug}}
      not Regex.match?(~r/^[a-z0-9-]+$/, slug) -> {:error, {:invalid_slug_chars, slug}}
      true -> :ok
    end
  end

  defp validate_slug(_), do: {:error, :slug_not_a_string}
end
