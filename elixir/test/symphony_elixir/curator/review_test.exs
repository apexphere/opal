defmodule SymphonyElixir.Curator.ReviewTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Curator.{Proposal, Review}
  alias SymphonyElixir.Wiki
  alias SymphonyElixir.Wiki.{Entry, Store}

  defmodule CapturingIO do
    @moduledoc false

    def start_link do
      Agent.start_link(fn -> [] end)
    end

    def puts(line) when is_binary(line) do
      pid = Process.get(:capturing_io_pid)
      Agent.update(pid, &[line | &1])
      :ok
    end

    def puts(other) do
      puts(to_string(other))
    end

    def lines do
      pid = Process.get(:capturing_io_pid)
      pid |> Agent.get(& &1) |> Enum.reverse()
    end
  end

  setup do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "opal-curator-review-#{System.unique_integer([:positive])}"
      )

    knowledge_root = Path.join(test_root, "knowledge")
    File.mkdir_p!(knowledge_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "apexphere/opal-review-test",
      knowledge_root: knowledge_root
    )

    {:ok, io_pid} = CapturingIO.start_link()
    Process.put(:capturing_io_pid, io_pid)

    on_exit(fn -> File.rm_rf(test_root) end)

    %{
      test_root: test_root,
      project_key: "github_apexphere_opal-review-test",
      io_pid: io_pid
    }
  end

  defp build_entry(slug, body) do
    %Entry{
      slug: slug,
      title: "Title for #{slug}",
      topic: "topic",
      revision: 1,
      created_at: "2026-04-20T00:00:00Z",
      updated_at: "2026-04-20T00:00:00Z",
      body: body
    }
  end

  describe "unified_diff/3" do
    test "produces a diff with --- / +++ headers and additions" do
      diff = Review.unified_diff("", "new line\nsecond", "wiki/foo.md")
      assert diff =~ "--- a/wiki/foo.md"
      assert diff =~ "+++ b/wiki/foo.md"
      assert diff =~ "+new line"
      assert diff =~ "+second"
    end

    test "shows deletions with - prefix" do
      diff = Review.unified_diff("kept\nremoved", "kept", "wiki/foo.md")
      assert diff =~ "-removed"
      refute diff =~ "+kept"
    end

    test "empty additions and deletions produce headers only" do
      diff = Review.unified_diff("same", "same", "wiki/foo.md")
      assert diff =~ "--- a/wiki/foo.md"
      refute diff =~ "+same"
      refute diff =~ "-same"
    end
  end

  describe "run/3 — :reject" do
    test "renders the rationale and returns :rejected without prompting", ctx do
      proposal = Proposal.reject("off topic")

      assert :rejected =
               Review.run(proposal, ctx.project_key,
                 io: CapturingIO,
                 input_fun: fn _ -> raise "should not prompt on reject" end
               )

      assert Enum.any?(CapturingIO.lines(), &(&1 =~ "REJECT"))
    end
  end

  describe "run/3 — :create" do
    test "writes the entry on accept", ctx do
      proposal = Proposal.create(build_entry("alpha", "# Heading\n\nbody\n"), "novel")

      assert :accepted =
               Review.run(proposal, ctx.project_key,
                 io: CapturingIO,
                 input_fun: fn _ -> "a" end
               )

      assert {:ok, entry} = Wiki.get(ctx.project_key, "alpha")
      assert entry.body =~ "Heading"
    end

    test "rejects without writing", ctx do
      proposal = Proposal.create(build_entry("alpha", "body"), "rationale")

      assert :rejected =
               Review.run(proposal, ctx.project_key,
                 io: CapturingIO,
                 input_fun: fn _ -> "r" end
               )

      refute Wiki.exists?(ctx.project_key, "alpha")
    end

    test "quits without writing", ctx do
      proposal = Proposal.create(build_entry("alpha", "body"), "rationale")

      assert :quit =
               Review.run(proposal, ctx.project_key,
                 io: CapturingIO,
                 input_fun: fn _ -> "q" end
               )

      refute Wiki.exists?(ctx.project_key, "alpha")
    end

    test "edit-then-accept passes body through editor_fun", ctx do
      proposal = Proposal.create(build_entry("alpha", "# orig\n"), "rationale")

      assert :accepted =
               Review.run(proposal, ctx.project_key,
                 io: CapturingIO,
                 input_fun: fn _ -> "e" end,
                 editor_fun: fn body -> body <> "edited\n" end
               )

      assert {:ok, entry} = Wiki.get(ctx.project_key, "alpha")
      assert entry.body =~ "edited"
    end

    test "loops on unrecognized input until a valid choice is made", ctx do
      proposal = Proposal.create(build_entry("alpha", "body"), "rationale")
      answers = ["?", "huh", "r"]
      counter = :counters.new(1, [])

      input_fun = fn _ ->
        i = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)
        Enum.at(answers, i, "r")
      end

      assert :rejected = Review.run(proposal, ctx.project_key, io: CapturingIO, input_fun: input_fun)
    end
  end

  describe "run/3 — :refine" do
    setup ctx do
      :ok = Wiki.put(ctx.project_key, build_entry("auth-tokens", "# v1\n\nold body\n"))
      :ok
    end

    test "increments revision and updates body on accept", ctx do
      proposal = Proposal.refine("auth-tokens", "# v2\n\nnew body\n", "duplicate found")

      assert :accepted =
               Review.run(proposal, ctx.project_key,
                 io: CapturingIO,
                 input_fun: fn _ -> "a" end
               )

      assert {:ok, refined} = Wiki.get(ctx.project_key, "auth-tokens")
      assert refined.revision == 2
      assert refined.body =~ "v2"
    end

    test "renders a diff against the existing entry body", ctx do
      proposal = Proposal.refine("auth-tokens", "# v2\n\nnew body\n", "dup")

      :rejected =
        Review.run(proposal, ctx.project_key,
          io: CapturingIO,
          input_fun: fn _ -> "r" end
        )

      output = Enum.join(CapturingIO.lines(), "\n")
      assert output =~ "-old body"
      assert output =~ "+new body"
    end

    test "errors when target slug is missing at write time", ctx do
      :ok = Wiki.put(ctx.project_key, build_entry("scratch", "body"))
      proposal = Proposal.refine("scratch", "new body", "dup")
      # Now delete it before run completes — simulate race
      File.rm!(Store.entry_path(Wiki.root!(), ctx.project_key, "scratch"))

      assert {:error, _} =
               Review.run(proposal, ctx.project_key,
                 io: CapturingIO,
                 input_fun: fn _ -> "a" end
               )
    end
  end
end
