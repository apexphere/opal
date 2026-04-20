defmodule SymphonyElixir.Wiki.Entry do
  @moduledoc """
  Parses and serializes wiki entries: YAML frontmatter + markdown body.

  An entry on disk is shaped like:

      ---
      slug: react-hooks-cleanup
      title: useEffect cleanup runs before next effect
      topic: react/hooks
      revision: 2
      created_at: 2026-04-20T11:02:00Z
      updated_at: 2026-04-20T15:18:00Z
      sources:
        - kind: article
          ref: docs/feeds/react-cleanup.md
          ingested_at: 2026-04-20T11:02:00Z
      related: [react-strictmode]
      confidence: high
      status: active
      ---
      # body markdown

  Frontmatter is the structured contract. Body is free-form markdown that
  may include `[[other-slug]]` cross-links for the LLM to follow.
  """

  @enforce_keys [:slug, :title, :topic, :revision, :created_at, :updated_at, :body]
  defstruct slug: nil,
            title: nil,
            topic: nil,
            revision: 1,
            created_at: nil,
            updated_at: nil,
            sources: [],
            related: [],
            confidence: "medium",
            status: "active",
            body: ""

  @type source :: %{
          required(:kind) => String.t(),
          required(:ref) => String.t(),
          required(:ingested_at) => String.t()
        }

  @type t :: %__MODULE__{
          slug: String.t(),
          title: String.t(),
          topic: String.t(),
          revision: pos_integer(),
          created_at: String.t(),
          updated_at: String.t(),
          sources: [source()],
          related: [String.t()],
          confidence: String.t(),
          status: String.t(),
          body: String.t()
        }

  @type summary :: %{
          required(:slug) => String.t(),
          required(:title) => String.t(),
          required(:topic) => String.t(),
          required(:one_line) => String.t()
        }

  @max_slug_length 60
  @valid_status ~w(active deprecated stale)
  @valid_confidence ~w(low medium high)

  @doc """
  Parses an on-disk entry (raw binary) into an `Entry` struct.
  """
  @spec parse(binary()) :: {:ok, t()} | {:error, term()}
  def parse(raw) when is_binary(raw) do
    with {:ok, frontmatter_yaml, body} <- split_frontmatter(raw),
         {:ok, attrs} <- parse_yaml(frontmatter_yaml),
         {:ok, normalized} <- normalize_attrs(attrs, body) do
      build(normalized)
    end
  end

  @doc """
  Serializes an `Entry` struct back to its on-disk format.
  """
  @spec serialize(t()) :: binary()
  def serialize(%__MODULE__{} = entry) do
    frontmatter = serialize_frontmatter(entry)
    "---\n" <> frontmatter <> "---\n" <> entry.body
  end

  @doc """
  Returns the compact summary used for prompt context.

  `:one_line` is the first non-blank line of the body, with markdown heading
  prefixes stripped. This is what the LLM sees when judging relevance.
  """
  @spec summary(t()) :: summary()
  def summary(%__MODULE__{} = entry) do
    %{
      slug: entry.slug,
      title: entry.title,
      topic: entry.topic,
      one_line: first_meaningful_line(entry.body)
    }
  end

  @doc """
  Sanitizes a candidate slug to `[a-z0-9-]` and caps to 60 chars. Returns
  the canonical kebab-case form. Empty input returns `{:error, :empty_slug}`.
  """
  @spec sanitize_slug(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def sanitize_slug(candidate) when is_binary(candidate) do
    cleaned =
      candidate
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, @max_slug_length)

    case cleaned do
      "" -> {:error, :empty_slug}
      slug -> {:ok, slug}
    end
  end

  @doc """
  Resolves slug collisions by appending `-2`, `-3`, etc. The `taken?` predicate
  is asked once per candidate suffix and must return `true` if the slug is taken.
  """
  @spec resolve_collision(String.t(), (String.t() -> boolean())) :: String.t()
  def resolve_collision(base_slug, taken?) when is_binary(base_slug) and is_function(taken?, 1) do
    case taken?.(base_slug) do
      false -> base_slug
      true -> next_unique(base_slug, 2, taken?)
    end
  end

  @doc "Returns the maximum permitted slug length."
  @spec max_slug_length() :: pos_integer()
  def max_slug_length, do: @max_slug_length

  defp next_unique(base, n, taken?) do
    candidate = "#{base}-#{n}"

    case taken?.(candidate) do
      false -> candidate
      true -> next_unique(base, n + 1, taken?)
    end
  end

  defp split_frontmatter(raw) do
    case raw do
      "---\n" <> rest ->
        case String.split(rest, "\n---\n", parts: 2) do
          [frontmatter, body] -> {:ok, frontmatter, body}
          _ -> {:error, :missing_frontmatter_terminator}
        end

      _ ->
        {:error, :missing_frontmatter}
    end
  end

  defp parse_yaml(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, attrs} when is_map(attrs) -> {:ok, attrs}
      {:ok, _other} -> {:error, :frontmatter_not_a_map}
      {:error, reason} -> {:error, {:invalid_frontmatter_yaml, reason}}
    end
  end

  defp normalize_attrs(attrs, body) do
    revision = Map.get(attrs, "revision", 1)
    sources = normalize_sources(Map.get(attrs, "sources", []))
    related = normalize_related(Map.get(attrs, "related", []))

    {:ok,
     %{
       slug: Map.get(attrs, "slug"),
       title: Map.get(attrs, "title"),
       topic: Map.get(attrs, "topic", ""),
       revision: revision,
       created_at: Map.get(attrs, "created_at"),
       updated_at: Map.get(attrs, "updated_at"),
       sources: sources,
       related: related,
       confidence: Map.get(attrs, "confidence", "medium"),
       status: Map.get(attrs, "status", "active"),
       body: body
     }}
  end

  defp normalize_sources(list) when is_list(list) do
    Enum.map(list, fn
      %{} = entry ->
        %{
          kind: Map.get(entry, "kind") || Map.get(entry, :kind) || "unknown",
          ref: Map.get(entry, "ref") || Map.get(entry, :ref) || "",
          ingested_at: Map.get(entry, "ingested_at") || Map.get(entry, :ingested_at) || ""
        }

      other when is_binary(other) ->
        %{kind: "unknown", ref: other, ingested_at: ""}
    end)
  end

  defp normalize_sources(_), do: []

  defp normalize_related(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp normalize_related(_), do: []

  defp build(attrs) do
    case validate_required(attrs) do
      :ok ->
        case validate_enums(attrs) do
          :ok -> {:ok, struct(__MODULE__, attrs)}
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  defp validate_required(attrs) do
    cond do
      is_nil(attrs.slug) or attrs.slug == "" -> {:error, :missing_slug}
      is_nil(attrs.title) or attrs.title == "" -> {:error, :missing_title}
      is_nil(attrs.created_at) -> {:error, :missing_created_at}
      is_nil(attrs.updated_at) -> {:error, :missing_updated_at}
      true -> :ok
    end
  end

  defp validate_enums(attrs) do
    cond do
      attrs.confidence not in @valid_confidence ->
        {:error, {:invalid_confidence, attrs.confidence}}

      attrs.status not in @valid_status ->
        {:error, {:invalid_status, attrs.status}}

      not is_integer(attrs.revision) or attrs.revision < 1 ->
        {:error, {:invalid_revision, attrs.revision}}

      true ->
        :ok
    end
  end

  defp serialize_frontmatter(entry) do
    [
      "slug: #{entry.slug}\n",
      "title: #{escape_yaml_string(entry.title)}\n",
      "topic: #{escape_yaml_string(entry.topic)}\n",
      "revision: #{entry.revision}\n",
      "created_at: #{entry.created_at}\n",
      "updated_at: #{entry.updated_at}\n",
      "confidence: #{entry.confidence}\n",
      "status: #{entry.status}\n",
      serialize_sources(entry.sources),
      serialize_related(entry.related)
    ]
    |> IO.iodata_to_binary()
  end

  defp serialize_sources([]), do: "sources: []\n"

  defp serialize_sources(sources) do
    [
      "sources:\n",
      Enum.map(sources, fn source ->
        [
          "  - kind: #{escape_yaml_string(source.kind)}\n",
          "    ref: #{escape_yaml_string(source.ref)}\n",
          "    ingested_at: #{source.ingested_at}\n"
        ]
      end)
    ]
    |> IO.iodata_to_binary()
  end

  defp serialize_related([]), do: "related: []\n"

  defp serialize_related(related) do
    "related: [" <> Enum.map_join(related, ", ", & &1) <> "]\n"
  end

  defp escape_yaml_string(value) when is_binary(value) do
    cond do
      String.contains?(value, "\n") ->
        ~s("#{String.replace(value, "\"", "\\\"")}")

      String.contains?(value, [":", "#", "\""]) ->
        ~s("#{String.replace(value, "\"", "\\\"")}")

      true ->
        value
    end
  end

  defp first_meaningful_line(body) do
    body
    |> String.split("\n")
    |> Enum.find_value("", fn line ->
      trimmed = String.trim(line)

      cond do
        trimmed == "" -> nil
        String.starts_with?(trimmed, "#") -> String.trim_leading(trimmed, "# ")
        true -> trimmed
      end
    end)
    |> String.slice(0, 200)
  end
end
