defmodule SymphonyElixir.Wiki.StoreTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Wiki.{Entry, Store}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "opal-wiki-store-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, project_key: "test_project"}
  end

  defp entry(slug, title \\ "Title", body \\ "body\n") do
    %Entry{
      slug: slug,
      title: title,
      topic: "topic",
      revision: 1,
      created_at: "2026-04-20T00:00:00Z",
      updated_at: "2026-04-20T00:00:00Z",
      sources: [],
      related: [],
      confidence: "medium",
      status: "active",
      body: body
    }
  end

  describe "list_slugs/2" do
    test "returns empty list when wiki dir is missing", ctx do
      assert {:ok, []} = Store.list_slugs(ctx.root, ctx.project_key)
    end

    test "returns sorted slugs", ctx do
      :ok = Store.put(ctx.root, ctx.project_key, entry("zeta"))
      :ok = Store.put(ctx.root, ctx.project_key, entry("alpha"))

      assert {:ok, ["alpha", "zeta"]} = Store.list_slugs(ctx.root, ctx.project_key)
    end

    test "ignores non-md files", ctx do
      :ok = Store.put(ctx.root, ctx.project_key, entry("real"))

      File.write!(
        Path.join(Store.dir(ctx.root, ctx.project_key), "stray.txt"),
        "ignore me"
      )

      assert {:ok, ["real"]} = Store.list_slugs(ctx.root, ctx.project_key)
    end

    test "propagates non-enoent errors", ctx do
      file_as_dir = Path.join(ctx.root, ctx.project_key)
      File.mkdir_p!(file_as_dir)
      File.write!(Path.join(file_as_dir, "wiki"), "I am a file")

      assert {:error, :enotdir} = Store.list_slugs(ctx.root, ctx.project_key)
    end
  end

  describe "put/3" do
    test "creates parent directories and writes serialized entry", ctx do
      :ok = Store.put(ctx.root, ctx.project_key, entry("foo"))

      path = Store.entry_path(ctx.root, ctx.project_key, "foo")
      assert File.exists?(path)
      assert File.read!(path) =~ "slug: foo"
    end

    test "is atomic (no .tmp left behind on success)", ctx do
      :ok = Store.put(ctx.root, ctx.project_key, entry("foo"))
      tmp_path = Store.entry_path(ctx.root, ctx.project_key, "foo") <> ".tmp"
      refute File.exists?(tmp_path)
    end

    test "rejects empty slug", ctx do
      bad = %{entry("foo") | slug: ""}
      assert {:error, :empty_slug} = Store.put(ctx.root, ctx.project_key, bad)
    end

    test "rejects slug with traversal sequences", ctx do
      bad = %{entry("foo") | slug: "../etc"}
      assert {:error, {:unsafe_slug, "../etc"}} = Store.put(ctx.root, ctx.project_key, bad)
    end

    test "rejects slug with slashes", ctx do
      bad = %{entry("foo") | slug: "a/b"}
      assert {:error, {:unsafe_slug, "a/b"}} = Store.put(ctx.root, ctx.project_key, bad)
    end

    test "rejects slug with invalid characters", ctx do
      bad = %{entry("foo") | slug: "Foo"}
      assert {:error, {:invalid_slug_chars, "Foo"}} = Store.put(ctx.root, ctx.project_key, bad)
    end

    test "rejects non-binary slug", ctx do
      bad = %{entry("foo") | slug: nil}
      assert {:error, :slug_not_a_string} = Store.put(ctx.root, ctx.project_key, bad)
    end
  end

  describe "get/3" do
    test "round-trips an entry through put/get", ctx do
      original = entry("foo", "My Title", "# Body\n\nbody text\n")
      :ok = Store.put(ctx.root, ctx.project_key, original)

      assert {:ok, loaded} = Store.get(ctx.root, ctx.project_key, "foo")
      assert loaded.title == "My Title"
      assert loaded.body =~ "body text"
    end

    test "returns enoent for missing slug", ctx do
      assert {:error, :enoent} = Store.get(ctx.root, ctx.project_key, "nope")
    end
  end

  describe "delete/3" do
    test "removes the entry file", ctx do
      :ok = Store.put(ctx.root, ctx.project_key, entry("foo"))
      :ok = Store.delete(ctx.root, ctx.project_key, "foo")

      refute File.exists?(Store.entry_path(ctx.root, ctx.project_key, "foo"))
    end

    test "is idempotent on missing slug", ctx do
      assert :ok = Store.delete(ctx.root, ctx.project_key, "never-existed")
    end

    test "surfaces non-enoent errors from File.rm", ctx do
      # Create a DIRECTORY at the would-be entry path. File.rm returns
      # {:error, :eperm} rather than removing it, exercising the non-enoent
      # branch.
      entry_dir = Store.entry_path(ctx.root, ctx.project_key, "collision")
      File.mkdir_p!(entry_dir)

      assert {:error, _reason} = Store.delete(ctx.root, ctx.project_key, "collision")
    end
  end
end
