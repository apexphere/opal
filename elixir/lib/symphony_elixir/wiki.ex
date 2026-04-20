defmodule SymphonyElixir.Wiki do
  @moduledoc """
  Public API for Opal's per-project LLM wiki.

  The wiki is a flat collection of markdown entries (frontmatter + body) that
  the curator distills from articles, then injects into agent workspaces at
  the start of each issue. Entries are immutable in slug; refinements bump
  `revision` and update body in place.

  The wiki is the substrate for Opal's self-learning pillar — distinct from
  the experience-knowledge subsystem (`SymphonyElixir.Knowledge`) which holds
  CLAUDE.md/skills/memory authored by humans or curator-learning loops.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Wiki.{Entry, Store}

  @doc "Returns summaries for every entry in the project, sorted by slug."
  @spec list_summaries(String.t()) :: {:ok, [Entry.summary()]} | {:error, term()}
  def list_summaries(project_key) when is_binary(project_key) do
    root = root!()

    with {:ok, slugs} <- Store.list_slugs(root, project_key) do
      summaries =
        slugs
        |> Enum.map(&summary_for(root, project_key, &1))
        |> Enum.reject(&is_nil/1)

      {:ok, summaries}
    end
  end

  defp summary_for(root, project_key, slug) do
    case Store.get(root, project_key, slug) do
      {:ok, entry} -> Entry.summary(entry)
      _ -> nil
    end
  end

  @doc "Reads an entry by slug."
  @spec get(String.t(), String.t()) :: {:ok, Entry.t()} | {:error, term()}
  def get(project_key, slug) when is_binary(project_key) and is_binary(slug) do
    Store.get(root!(), project_key, slug)
  end

  @doc """
  Persists `entry` (create or refine). Atomic write at the store level.

  This is the only intended write path; the curator review CLI calls this on
  human accept.
  """
  @spec put(String.t(), Entry.t(), keyword()) :: :ok | {:error, term()}
  def put(project_key, %Entry{} = entry, _opts \\ []) when is_binary(project_key) do
    Store.put(root!(), project_key, entry)
  end

  @doc """
  Returns whether `slug` already exists in the project's wiki.
  """
  @spec exists?(String.t(), String.t()) :: boolean()
  def exists?(project_key, slug) when is_binary(project_key) and is_binary(slug) do
    case Store.get(root!(), project_key, slug) do
      {:ok, _} -> true
      _ -> false
    end
  end

  @doc """
  Returns the resolved knowledge root for the wiki. Wiki and Knowledge share
  the same root by design — both are project-scoped.
  """
  @spec root!() :: Path.t()
  def root! do
    Config.settings!().knowledge.root
  end

  @doc """
  Phase 1 query: asks the configured query module to pick top-K entries
  relevant to `issue_context`. Returns a list of slugs.

  When no query module is configured, returns all entry slugs (capped at
  `:limit`, default 5) so the system degrades gracefully without an LLM.
  """
  @spec query(String.t(), map(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def query(project_key, issue_context, opts \\ []) do
    limit = Keyword.get(opts, :limit, 5)

    case query_module() do
      nil ->
        {:ok, summaries} = list_summaries(project_key)

        {:ok,
         summaries
         |> Enum.take(limit)
         |> Enum.map(& &1.slug)}

      module when is_atom(module) ->
        module.query(project_key, issue_context, opts)
    end
  end

  defp query_module do
    Application.get_env(:symphony_elixir, :wiki_query_module)
  end
end
