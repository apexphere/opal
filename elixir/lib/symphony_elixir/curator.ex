defmodule SymphonyElixir.Curator do
  @moduledoc """
  Orchestrates one article -> proposal cycle.

  Pipeline (Phase 1):
    1. Read the article (cap to 32 KB pre-LLM, reject hard above that).
    2. Load all entry summaries for the project (cap 200; pre-filter by
       topic substring against article first 200 chars when over).
    3. Pre-rank candidate full bodies (≤5) by topic-substring overlap so
       refinement context fits in one LLM call.
    4. Invoke the configured `Distiller` once. The distiller returns a
       structured `Proposal`.
    5. Sanitize the proposal:
         - On :reject -> pass through.
         - On {:create, _} -> sanitize/collision-resolve the slug, build
           a complete `Entry` with timestamps and source.
         - On {:refine, _} -> the input slug from the candidate set is
           authoritative; the distiller's slug is discarded.

  Phase 1 stops at the proposal — `put` is the human-review CLI's
  responsibility (see `Curator.Review`).
  """

  alias SymphonyElixir.Curator.Proposal
  alias SymphonyElixir.Wiki
  alias SymphonyElixir.Wiki.{Entry, Store}

  @max_article_bytes 32 * 1024
  @max_summaries 200
  @max_candidates 5

  @type opts :: [
          project_key: String.t(),
          source_ref: String.t() | nil,
          distiller: module() | nil,
          now: (-> String.t())
        ]

  @type result :: {:ok, Proposal.t()} | {:error, term()}

  @spec learn(Path.t(), opts()) :: result()
  def learn(article_path, opts \\ []) when is_binary(article_path) do
    project_key = Keyword.fetch!(opts, :project_key)
    source_ref = Keyword.get(opts, :source_ref, article_path)
    distiller = Keyword.get(opts, :distiller, default_distiller())
    now_fun = Keyword.get(opts, :now, &iso8601_now/0)
    now = now_fun.()

    with {:ok, raw_body} <- File.read(article_path),
         :ok <- check_size(raw_body),
         {:ok, summaries} <- Wiki.list_summaries(project_key),
         capped_summaries <- maybe_filter_summaries(summaries, raw_body),
         {:ok, candidates} <- load_candidates(project_key, raw_body, capped_summaries),
         {:ok, proposal} <-
           distiller.distill(
             %{body: raw_body, source_ref: source_ref, ingested_at: now},
             capped_summaries,
             candidates
           ) do
      sanitize_proposal(proposal, project_key, source_ref, now, raw_body)
    end
  end

  @doc "Returns the maximum article size accepted (in bytes)."
  @spec max_article_bytes() :: pos_integer()
  def max_article_bytes, do: @max_article_bytes

  defp check_size(body) when byte_size(body) <= @max_article_bytes, do: :ok
  defp check_size(body), do: {:error, {:article_too_large, byte_size(body), @max_article_bytes}}

  defp maybe_filter_summaries(summaries, _raw_body) when length(summaries) <= @max_summaries do
    summaries
  end

  defp maybe_filter_summaries(summaries, raw_body) do
    needles = body_needles(raw_body)

    summaries
    |> Enum.sort_by(&(-summary_overlap(&1, needles)))
    |> Enum.take(@max_summaries)
  end

  defp load_candidates(project_key, raw_body, summaries) do
    needles = body_needles(raw_body)
    root = Wiki.root!()

    candidates =
      summaries
      |> Enum.sort_by(&(-summary_overlap(&1, needles)))
      |> Enum.take(@max_candidates)
      |> Enum.map(fn summary ->
        {:ok, entry} = Store.get(root, project_key, summary.slug)
        entry
      end)

    {:ok, candidates}
  end

  defp body_needles(raw_body) do
    raw_body
    |> String.slice(0, 200)
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
    |> Enum.uniq()
  end

  defp summary_overlap(summary, needles) do
    haystack = String.downcase("#{summary.title} #{summary.topic} #{summary.one_line}")
    Enum.count(needles, &String.contains?(haystack, &1))
  end

  defp sanitize_proposal(%Proposal{decision: :reject} = proposal, _project_key, source_ref, _now, _body) do
    {:ok, %Proposal{proposal | source_ref: proposal.source_ref || source_ref}}
  end

  defp sanitize_proposal(%Proposal{decision: {:create, _slug, %Entry{} = entry}} = proposal, project_key, source_ref, now, _body) do
    with {:ok, base_slug} <- Entry.sanitize_slug(entry.slug),
         final_slug <-
           Entry.resolve_collision(base_slug, fn slug ->
             Wiki.exists?(project_key, slug)
           end) do
      finalized = %Entry{
        entry
        | slug: final_slug,
          revision: 1,
          created_at: now,
          updated_at: now,
          sources: ensure_source(entry.sources, source_ref, now),
          confidence: entry.confidence || "medium",
          status: entry.status || "active"
      }

      final_decision = {:create, final_slug, finalized}

      {:ok,
       %Proposal{
         proposal
         | decision: final_decision,
           producer_decision: final_decision,
           final_decision: final_decision,
           source_ref: proposal.source_ref || source_ref
       }}
    end
  end

  defp sanitize_proposal(
         %Proposal{decision: {:refine, slug, merged_body}} = proposal,
         project_key,
         source_ref,
         _now,
         _body
       ) do
    case Wiki.exists?(project_key, slug) do
      true ->
        final_decision = {:refine, slug, merged_body}

        {:ok,
         %Proposal{
           proposal
           | decision: final_decision,
             producer_decision: final_decision,
             final_decision: final_decision,
             source_ref: proposal.source_ref || source_ref
         }}

      false ->
        {:error, {:refine_target_missing, slug}}
    end
  end

  defp ensure_source(sources, source_ref, now) when is_list(sources) do
    sources ++ [%{kind: "article", ref: source_ref, ingested_at: now}]
  end

  defp default_distiller do
    Application.get_env(
      :symphony_elixir,
      :curator_distiller_module,
      SymphonyElixir.Curator.Distillers.Article
    )
  end

  defp iso8601_now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
