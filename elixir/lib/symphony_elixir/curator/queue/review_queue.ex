defmodule SymphonyElixir.Curator.Queue.ReviewQueue do
  @moduledoc """
  Parks curator proposals that need human adjudication as JSON files under
  `<knowledge_root>/<project>/review-queue/`. The `mix opal.review` task
  drains this directory and replays each proposal through the interactive
  review CLI.

  Proposals are serialized deterministically (no timestamps inside the
  payload beyond what's already on the `Entry`). Filenames contain both a
  human-readable slug hint and a unix timestamp so the order of review
  matches the order of arrival.
  """

  require Logger

  alias SymphonyElixir.Curator.Proposal
  alias SymphonyElixir.Wiki
  alias SymphonyElixir.Wiki.Entry

  @review_queue_subdir "review-queue"

  @doc """
  Writes `proposal` to the project's review queue. Returns `:ok` on
  success, `{:error, reason}` on filesystem failure.
  """
  @spec park(String.t(), Proposal.t()) :: :ok | {:error, term()}
  def park(project_key, %Proposal{} = proposal) do
    dir = queue_dir(project_key)
    File.mkdir_p!(dir)

    file = Path.join(dir, filename_for(proposal))

    case File.write(file, encode(proposal)) do
      :ok ->
        Logger.info("Curator.Queue parked proposal for review path=#{file}")
        :ok

      {:error, reason} = error ->
        Logger.warning("Curator.Queue could not park proposal reason=#{inspect(reason)}")
        error
    end
  end

  @doc "Returns the review-queue directory for a project."
  @spec queue_dir(String.t()) :: Path.t()
  def queue_dir(project_key) do
    Path.join([Wiki.root!(), project_key, @review_queue_subdir])
  end

  @doc """
  Lists parked proposal files for `project_key`, sorted by filename
  (which embeds the unix timestamp, so oldest first).
  """
  @spec list(String.t()) :: [Path.t()]
  def list(project_key) do
    dir = queue_dir(project_key)

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.sort()
        |> Enum.map(&Path.join(dir, &1))

      {:error, _} ->
        []
    end
  end

  @doc "Reads and decodes a parked proposal."
  @spec read(Path.t()) :: {:ok, Proposal.t()} | {:error, term()}
  def read(path) when is_binary(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, map} <- Jason.decode(raw) do
      decode(map)
    end
  end

  @doc "Removes a parked proposal file (after it has been reviewed)."
  @spec delete(Path.t()) :: :ok | {:error, term()}
  def delete(path) when is_binary(path) do
    File.rm(path)
  end

  @doc false
  @spec encode(Proposal.t()) :: binary()
  def encode(%Proposal{} = proposal) do
    Jason.encode!(%{
      "decision" => encode_decision(proposal.decision),
      "producer_decision" => encode_decision(proposal.producer_decision),
      "critic_verdict" => encode_verdict(proposal.critic_verdict),
      "final_decision" => encode_decision(proposal.final_decision),
      "rationale" => proposal.rationale,
      "source_ref" => proposal.source_ref
    })
  end

  @doc false
  @spec decode(map()) :: {:ok, Proposal.t()} | {:error, term()}
  def decode(%{"decision" => decision_map} = map) do
    with {:ok, decision} <- decode_decision(decision_map),
         {:ok, producer} <- decode_decision(Map.get(map, "producer_decision", decision_map)),
         {:ok, final} <- decode_decision(Map.get(map, "final_decision", decision_map)) do
      verdict = decode_verdict(Map.get(map, "critic_verdict"))

      {:ok,
       %Proposal{
         decision: decision,
         producer_decision: producer,
         critic_verdict: verdict,
         final_decision: final,
         rationale: Map.get(map, "rationale", ""),
         source_ref: Map.get(map, "source_ref")
       }}
    end
  end

  def decode(_), do: {:error, :invalid_payload}

  defp encode_decision(:reject), do: %{"kind" => "reject"}

  defp encode_decision({:create, slug, %Entry{} = entry}) do
    %{"kind" => "create", "slug" => slug, "entry" => encode_entry(entry)}
  end

  defp encode_decision({:refine, slug, merged_body}) do
    %{"kind" => "refine", "slug" => slug, "merged_body" => merged_body}
  end

  defp encode_decision({:human_review, producer, verdict}) do
    %{
      "kind" => "human_review",
      "producer" => encode_decision(producer),
      "verdict" => encode_verdict(verdict)
    }
  end

  defp encode_entry(%Entry{} = entry) do
    %{
      "slug" => entry.slug,
      "title" => entry.title,
      "topic" => entry.topic,
      "revision" => entry.revision,
      "created_at" => entry.created_at,
      "updated_at" => entry.updated_at,
      "sources" => entry.sources,
      "related" => entry.related,
      "confidence" => entry.confidence,
      "status" => entry.status,
      "body" => entry.body
    }
  end

  defp encode_verdict(:approve), do: %{"kind" => "approve"}
  defp encode_verdict({:reject, reason}), do: %{"kind" => "reject", "reason" => reason}

  defp encode_verdict({:conflict, slug, reason}),
    do: %{"kind" => "conflict", "slug" => slug, "reason" => reason}

  defp encode_verdict(nil), do: nil

  defp decode_decision(%{"kind" => "reject"}), do: {:ok, :reject}

  defp decode_decision(%{"kind" => "create", "slug" => slug, "entry" => entry_map}) do
    {:ok, {:create, slug, decode_entry(entry_map)}}
  end

  defp decode_decision(%{"kind" => "refine", "slug" => slug, "merged_body" => merged_body}) do
    {:ok, {:refine, slug, merged_body}}
  end

  defp decode_decision(%{"kind" => "human_review", "producer" => producer} = map) do
    with {:ok, producer_decision} <- decode_decision(producer) do
      {:ok, {:human_review, producer_decision, decode_verdict(Map.get(map, "verdict"))}}
    end
  end

  defp decode_entry(%{} = map) do
    %Entry{
      slug: Map.fetch!(map, "slug"),
      title: Map.fetch!(map, "title"),
      topic: Map.fetch!(map, "topic"),
      revision: Map.fetch!(map, "revision"),
      created_at: Map.fetch!(map, "created_at"),
      updated_at: Map.fetch!(map, "updated_at"),
      sources: atomize_sources(Map.get(map, "sources", [])),
      related: Map.get(map, "related", []),
      confidence: Map.get(map, "confidence", "medium"),
      status: Map.get(map, "status", "active"),
      body: Map.fetch!(map, "body")
    }
  end

  defp atomize_sources(sources) when is_list(sources) do
    Enum.map(sources, fn %{"kind" => kind, "ref" => ref, "ingested_at" => ingested_at} ->
      %{kind: kind, ref: ref, ingested_at: ingested_at}
    end)
  end

  defp decode_verdict(%{"kind" => "approve"}), do: :approve
  defp decode_verdict(%{"kind" => "reject", "reason" => reason}), do: {:reject, reason}

  defp decode_verdict(%{"kind" => "conflict", "slug" => slug, "reason" => reason}),
    do: {:conflict, slug, reason}

  defp decode_verdict(nil), do: nil

  defp filename_for(%Proposal{} = proposal) do
    slug_hint = slug_hint(proposal)
    ts = System.system_time(:second)
    "#{slug_hint}-#{ts}.json"
  end

  defp slug_hint(%Proposal{decision: :reject}), do: "reject"

  defp slug_hint(%Proposal{decision: {:create, slug, _}}), do: slug
  defp slug_hint(%Proposal{decision: {:refine, slug, _}}), do: slug

  defp slug_hint(%Proposal{decision: {:human_review, producer, _}}) do
    case producer do
      {:create, slug, _} -> "hr-#{slug}"
      {:refine, slug, _} -> "hr-#{slug}"
    end
  end
end
