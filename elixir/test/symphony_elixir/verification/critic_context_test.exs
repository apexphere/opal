defmodule SymphonyElixir.Verification.CriticContextTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Verification.CriticContext

  defmodule StubGit do
    @moduledoc false
    @behaviour SymphonyElixir.Verification.CriticContext.Git

    @impl true
    def merge_base(_workspace) do
      case Process.get(:stub_merge_base) do
        nil -> {:error, :not_set}
        value -> value
      end
    end

    @impl true
    def diff(_workspace, _base) do
      case Process.get(:stub_diff) do
        nil -> {:error, :not_set}
        value -> value
      end
    end

    def set_merge_base(value), do: Process.put(:stub_merge_base, value)
    def set_diff(value), do: Process.put(:stub_diff, value)
  end

  describe "task_summary" do
    test "combines title and description with a blank line" do
      issue = %{title: "Add --json flag", description: "Users asked for machine-readable output"}

      %{task_summary: summary} = CriticContext.derive(issue, nil)

      assert summary == "Add --json flag\n\nUsers asked for machine-readable output"
    end

    test "uses title alone when description is empty" do
      issue = %{title: "Rename foo", description: ""}
      assert %{task_summary: "Rename foo"} = CriticContext.derive(issue, nil)
    end

    test "uses title alone when description is nil" do
      issue = %{title: "Rename foo", description: nil}
      assert %{task_summary: "Rename foo"} = CriticContext.derive(issue, nil)
    end

    test "uses description alone when title is empty" do
      issue = %{title: "", description: "body only"}
      assert %{task_summary: "body only"} = CriticContext.derive(issue, nil)
    end

    test "returns empty string when both title and description are blank" do
      assert %{task_summary: ""} = CriticContext.derive(%{title: "   ", description: nil}, nil)
    end

    test "returns empty string when issue is nil" do
      assert %{task_summary: ""} = CriticContext.derive(nil, nil)
    end

    test "trims whitespace from title and description" do
      issue = %{title: "  Padded  ", description: "\n\nbody\n\n"}
      assert %{task_summary: "Padded\n\nbody"} = CriticContext.derive(issue, nil)
    end

    test "truncates oversize summaries with an ellipsis marker" do
      long_body = String.duplicate("x", CriticContext.task_summary_limit() + 200)
      issue = %{title: "t", description: long_body}

      %{task_summary: summary} = CriticContext.derive(issue, nil)

      # Cap at the limit plus the trailing "\n…" marker.
      assert byte_size(summary) <= CriticContext.task_summary_limit() + 4
      assert String.ends_with?(summary, "…")
    end
  end

  describe "diff via the git seam" do
    setup do
      StubGit.set_merge_base(nil)
      StubGit.set_diff(nil)
      :ok
    end

    test "returns empty string when workspace_path is nil" do
      assert %{diff: ""} = CriticContext.derive(%{title: "t"}, nil, git_module: StubGit)
    end

    test "returns the diff when both git calls succeed" do
      StubGit.set_merge_base({:ok, "abc123\n"})
      StubGit.set_diff({:ok, "diff body"})

      assert %{diff: "diff body"} =
               CriticContext.derive(%{title: "t"}, "/tmp/ws", git_module: StubGit)
    end

    test "returns empty string when merge_base fails" do
      StubGit.set_merge_base({:error, :nope})

      assert %{diff: ""} =
               CriticContext.derive(%{title: "t"}, "/tmp/ws", git_module: StubGit)
    end

    test "returns empty string when diff fails" do
      StubGit.set_merge_base({:ok, "abc"})
      StubGit.set_diff({:error, :nope})

      assert %{diff: ""} =
               CriticContext.derive(%{title: "t"}, "/tmp/ws", git_module: StubGit)
    end

    test "truncates oversize diffs with a head/tail split" do
      head_marker = "HEADSTART" <> String.duplicate("a", 5_000)
      middle = String.duplicate("m", CriticContext.diff_limit())
      tail_marker = String.duplicate("z", 5_000) <> "TAILEND"
      big_diff = head_marker <> middle <> tail_marker

      StubGit.set_merge_base({:ok, "abc"})
      StubGit.set_diff({:ok, big_diff})

      %{diff: diff} =
        CriticContext.derive(%{title: "t"}, "/tmp/ws", git_module: StubGit)

      assert String.starts_with?(diff, "HEADSTART")
      assert String.ends_with?(diff, "TAILEND")
      assert diff =~ "[truncated"
      # Split keeps 2 * head_tail + separator — much less than the raw input.
      assert byte_size(diff) < byte_size(big_diff)
    end

    test "passes workspace_path unchanged into the git module" do
      defmodule CaptureGit do
        @behaviour SymphonyElixir.Verification.CriticContext.Git
        @impl true
        def merge_base(path) do
          send(self(), {:merge_base_called, path})
          {:ok, "abc"}
        end

        @impl true
        def diff(path, base) do
          send(self(), {:diff_called, path, base})
          {:ok, "ok"}
        end
      end

      CriticContext.derive(%{title: "t"}, "/some/ws", git_module: CaptureGit)

      assert_received {:merge_base_called, "/some/ws"}
      assert_received {:diff_called, "/some/ws", "abc"}
    end
  end
end
