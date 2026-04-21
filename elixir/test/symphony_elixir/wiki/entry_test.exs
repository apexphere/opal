defmodule SymphonyElixir.Wiki.EntryTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Wiki.Entry

  @valid_raw """
  ---
  slug: react-hooks-cleanup
  title: useEffect cleanup runs before next effect
  topic: react/hooks
  revision: 2
  created_at: 2026-04-20T11:02:00Z
  updated_at: 2026-04-20T15:18:00Z
  confidence: high
  status: active
  sources:
    - kind: article
      ref: docs/feeds/react-cleanup.md
      ingested_at: 2026-04-20T11:02:00Z
  related: [react-strictmode]
  perfect_for:
    - subscribing to external data sources
    - timers tied to a component's lifetime
  not_ideal_for:
    - server-side rendering paths
    - empty-dep-array effects that never re-fire
  ---
  # useEffect cleanup

  Cleanup runs before the next effect, not just on unmount.
  """

  describe "parse/1" do
    test "round-trips frontmatter and body" do
      assert {:ok, entry} = Entry.parse(@valid_raw)
      assert entry.slug == "react-hooks-cleanup"
      assert entry.title =~ "useEffect cleanup"
      assert entry.topic == "react/hooks"
      assert entry.revision == 2
      assert entry.confidence == "high"
      assert entry.status == "active"
      assert entry.body =~ "# useEffect cleanup"
      assert [%{kind: "article", ref: "docs/feeds/react-cleanup.md"}] = entry.sources
      assert entry.related == ["react-strictmode"]
      assert entry.perfect_for == ["subscribing to external data sources", "timers tied to a component's lifetime"]
      assert entry.not_ideal_for == ["server-side rendering paths", "empty-dep-array effects that never re-fire"]
    end

    test "defaults perfect_for/not_ideal_for to [] when absent" do
      raw = """
      ---
      slug: foo
      title: t
      created_at: 2026-04-20T00:00:00Z
      updated_at: 2026-04-20T00:00:00Z
      ---
      body
      """

      assert {:ok, entry} = Entry.parse(raw)
      assert entry.perfect_for == []
      assert entry.not_ideal_for == []
    end

    test "tolerates non-list perfect_for / not_ideal_for" do
      raw = """
      ---
      slug: foo
      title: t
      created_at: 2026-04-20T00:00:00Z
      updated_at: 2026-04-20T00:00:00Z
      perfect_for: "oops"
      not_ideal_for: 42
      ---
      body
      """

      assert {:ok, entry} = Entry.parse(raw)
      assert entry.perfect_for == []
      assert entry.not_ideal_for == []
    end

    test "coerces non-string items in perfect_for" do
      raw = """
      ---
      slug: foo
      title: t
      created_at: 2026-04-20T00:00:00Z
      updated_at: 2026-04-20T00:00:00Z
      perfect_for:
        - 123
        - ""
        - "  trimmed  "
      ---
      body
      """

      assert {:ok, entry} = Entry.parse(raw)
      assert entry.perfect_for == ["123", "trimmed"]
    end

    test "rejects missing frontmatter" do
      assert {:error, :missing_frontmatter} = Entry.parse("# just body\n")
    end

    test "rejects unterminated frontmatter" do
      assert {:error, :missing_frontmatter_terminator} = Entry.parse("---\nslug: x\n")
    end

    test "rejects entry without slug" do
      raw = """
      ---
      title: oops
      created_at: 2026-04-20T00:00:00Z
      updated_at: 2026-04-20T00:00:00Z
      ---
      body
      """

      assert {:error, :missing_slug} = Entry.parse(raw)
    end

    test "rejects entry without title" do
      raw = """
      ---
      slug: foo
      created_at: 2026-04-20T00:00:00Z
      updated_at: 2026-04-20T00:00:00Z
      ---
      body
      """

      assert {:error, :missing_title} = Entry.parse(raw)
    end

    test "rejects entry with invalid status" do
      raw = """
      ---
      slug: foo
      title: t
      created_at: 2026-04-20T00:00:00Z
      updated_at: 2026-04-20T00:00:00Z
      status: bogus
      ---
      body
      """

      assert {:error, {:invalid_status, "bogus"}} = Entry.parse(raw)
    end

    test "rejects entry with invalid confidence" do
      raw = """
      ---
      slug: foo
      title: t
      created_at: 2026-04-20T00:00:00Z
      updated_at: 2026-04-20T00:00:00Z
      confidence: bogus
      ---
      body
      """

      assert {:error, {:invalid_confidence, "bogus"}} = Entry.parse(raw)
    end

    test "rejects revision not a positive integer" do
      raw = """
      ---
      slug: foo
      title: t
      revision: 0
      created_at: 2026-04-20T00:00:00Z
      updated_at: 2026-04-20T00:00:00Z
      ---
      body
      """

      assert {:error, {:invalid_revision, 0}} = Entry.parse(raw)
    end

    test "rejects entry without created_at/updated_at" do
      no_created = """
      ---
      slug: foo
      title: t
      updated_at: 2026-04-20T00:00:00Z
      ---
      body
      """

      assert {:error, :missing_created_at} = Entry.parse(no_created)

      no_updated = """
      ---
      slug: foo
      title: t
      created_at: 2026-04-20T00:00:00Z
      ---
      body
      """

      assert {:error, :missing_updated_at} = Entry.parse(no_updated)
    end

    test "rejects frontmatter that is not a YAML map" do
      raw = """
      ---
      - just
      - a
      - list
      ---
      body
      """

      assert {:error, :frontmatter_not_a_map} = Entry.parse(raw)
    end

    test "rejects malformed YAML in frontmatter" do
      raw = """
      ---
      slug: foo
        : badly: indented
      ---
      body
      """

      assert {:error, {:invalid_frontmatter_yaml, _}} = Entry.parse(raw)
    end

    test "tolerates string sources" do
      raw = """
      ---
      slug: foo
      title: t
      created_at: 2026-04-20T00:00:00Z
      updated_at: 2026-04-20T00:00:00Z
      sources:
        - "raw-string-ref"
      ---
      body
      """

      assert {:ok, entry} = Entry.parse(raw)
      assert [%{kind: "unknown", ref: "raw-string-ref"}] = entry.sources
    end
  end

  describe "serialize/1" do
    test "is parseable round-trip" do
      {:ok, entry} = Entry.parse(@valid_raw)
      raw = Entry.serialize(entry)
      assert {:ok, parsed} = Entry.parse(raw)
      assert parsed.slug == entry.slug
      assert parsed.title == entry.title
      assert parsed.revision == entry.revision
      assert parsed.body == entry.body
      assert parsed.related == entry.related
      assert [%{kind: "article", ref: "docs/feeds/react-cleanup.md"}] = parsed.sources
    end

    test "serializes empty sources and related as empty lists" do
      entry = %Entry{
        slug: "x",
        title: "y",
        topic: "",
        revision: 1,
        created_at: "2026-04-20T00:00:00Z",
        updated_at: "2026-04-20T00:00:00Z",
        sources: [],
        related: [],
        confidence: "medium",
        status: "active",
        body: "body\n"
      }

      raw = Entry.serialize(entry)
      assert raw =~ "sources: []"
      assert raw =~ "related: []"
      assert raw =~ "perfect_for: []"
      assert raw =~ "not_ideal_for: []"
    end

    test "serializes perfect_for / not_ideal_for as YAML lists" do
      entry = %Entry{
        slug: "x",
        title: "y",
        topic: "",
        revision: 1,
        created_at: "2026-04-20T00:00:00Z",
        updated_at: "2026-04-20T00:00:00Z",
        perfect_for: ["case a", "case b"],
        not_ideal_for: ["anti a"],
        body: "body\n"
      }

      raw = Entry.serialize(entry)
      assert raw =~ "perfect_for:\n  - case a\n  - case b\n"
      assert raw =~ "not_ideal_for:\n  - anti a\n"

      assert {:ok, parsed} = Entry.parse(raw)
      assert parsed.perfect_for == ["case a", "case b"]
      assert parsed.not_ideal_for == ["anti a"]
    end

    test "escapes title containing colon" do
      entry = %Entry{
        slug: "x",
        title: "useEffect: cleanup runs",
        topic: "",
        revision: 1,
        created_at: "2026-04-20T00:00:00Z",
        updated_at: "2026-04-20T00:00:00Z",
        body: "b"
      }

      raw = Entry.serialize(entry)
      assert {:ok, parsed} = Entry.parse(raw)
      assert parsed.title == "useEffect: cleanup runs"
    end
  end

  describe "summary/1" do
    test "extracts the first heading without leading hashes" do
      {:ok, entry} = Entry.parse(@valid_raw)
      summary = Entry.summary(entry)
      assert summary.slug == "react-hooks-cleanup"
      assert summary.one_line == "useEffect cleanup"
    end

    test "first non-blank line when body has no heading" do
      raw = """
      ---
      slug: x
      title: y
      created_at: 2026-04-20T00:00:00Z
      updated_at: 2026-04-20T00:00:00Z
      ---


      Cleanup runs before next effect.
      Second line ignored.
      """

      {:ok, entry} = Entry.parse(raw)
      assert Entry.summary(entry).one_line == "Cleanup runs before next effect."
    end
  end

  describe "sanitize_slug/1" do
    test "lowercases and replaces non-alphanumerics with dashes" do
      assert {:ok, "react-hooks-cleanup"} = Entry.sanitize_slug("React Hooks: Cleanup!")
    end

    test "trims leading/trailing dashes" do
      assert {:ok, "abc"} = Entry.sanitize_slug("---abc---")
    end

    test "caps to 60 characters" do
      candidate = String.duplicate("a", 100)
      assert {:ok, slug} = Entry.sanitize_slug(candidate)
      assert String.length(slug) == 60
    end

    test "returns error for empty input after sanitization" do
      assert {:error, :empty_slug} = Entry.sanitize_slug("!!!")
    end
  end

  describe "resolve_collision/2" do
    test "returns base slug when free" do
      assert "foo" = Entry.resolve_collision("foo", fn _ -> false end)
    end

    test "appends -2 on first collision" do
      assert "foo-2" = Entry.resolve_collision("foo", fn slug -> slug == "foo" end)
    end

    test "increments until free" do
      taken = MapSet.new(["foo", "foo-2", "foo-3"])
      assert "foo-4" = Entry.resolve_collision("foo", fn slug -> MapSet.member?(taken, slug) end)
    end
  end

  describe "max_slug_length/0" do
    test "returns the slug length cap" do
      assert Entry.max_slug_length() == 60
    end
  end

  describe "parse/1 — tolerant normalization" do
    test "treats a non-list `sources` value as empty" do
      raw = """
      ---
      slug: foo
      title: t
      created_at: 2026-04-20T00:00:00Z
      updated_at: 2026-04-20T00:00:00Z
      sources: "not a list"
      ---
      body
      """

      assert {:ok, entry} = Entry.parse(raw)
      assert entry.sources == []
    end

    test "treats a non-list `related` value as empty" do
      raw = """
      ---
      slug: foo
      title: t
      created_at: 2026-04-20T00:00:00Z
      updated_at: 2026-04-20T00:00:00Z
      related: "not a list"
      ---
      body
      """

      assert {:ok, entry} = Entry.parse(raw)
      assert entry.related == []
    end
  end

  describe "serialize/1 — escaping" do
    test "wraps a title containing a newline in quotes" do
      entry = %Entry{
        slug: "x",
        title: ~s(has "quote" and\nnewline),
        topic: "",
        revision: 1,
        created_at: "2026-04-20T00:00:00Z",
        updated_at: "2026-04-20T00:00:00Z",
        body: "b"
      }

      raw = Entry.serialize(entry)
      # Exercises the newline branch of escape_yaml_string/1: wraps in "…"
      # and backslash-escapes embedded quotes.
      assert raw =~ ~s(title: "has \\"quote\\")
    end
  end
end
