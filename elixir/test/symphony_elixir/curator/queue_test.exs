defmodule SymphonyElixir.Curator.QueueTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Curator.{Distillers, Proposal, Queue}
  alias SymphonyElixir.Curator.Queue.ReviewQueue
  alias SymphonyElixir.Wiki

  setup do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "opal-curator-queue-#{System.unique_integer([:positive])}"
      )

    knowledge_root = Path.join(test_root, "knowledge")
    File.mkdir_p!(knowledge_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "apexphere/opal-queue-test",
      knowledge_root: knowledge_root
    )

    Application.put_env(:symphony_elixir, :curator_failure_distiller_module, Distillers.Stub)
    Application.put_env(:symphony_elixir, :curator_critic_module, SymphonyElixir.Curator.Critics.Stub)
    Application.put_env(:symphony_elixir, :curator_stub_critic, :approve)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :curator_failure_distiller_module)
      Application.delete_env(:symphony_elixir, :curator_critic_module)
      Application.delete_env(:symphony_elixir, :curator_stub_response)
      Application.delete_env(:symphony_elixir, :curator_stub_critic)
      File.rm_rf(test_root)
    end)

    %{
      test_root: test_root,
      knowledge_root: knowledge_root,
      project_key: "github_apexphere_opal-queue-test"
    }
  end

  defp payload do
    %{
      recipe: %SymphonyElixir.Verification.Recipe{description: "desc", steps: []},
      failed_step: %{name: "ping", shell: "curl -fsS x"},
      output: "bad",
      issue_ref: "issue-1",
      started_at: "2026-04-20T00:00:00Z"
    }
  end

  defp wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("wait_until timed out")

      true ->
        Process.sleep(25)
        do_wait(fun, deadline)
    end
  end

  describe "start_link/1" do
    test "accepts a :name override and starts under caller's supervision" do
      {:ok, pid} = Queue.start_link(name: :test_queue_override)
      assert Process.alive?(pid)
      assert Process.whereis(:test_queue_override) == pid
      GenServer.stop(pid)
    end
  end

  describe "cast_failure/2 is robust" do
    test "never raises even if the Queue is missing" do
      # Temporarily hide the Queue by unregistering its name.
      pid = Process.whereis(Queue)
      Process.unregister(Queue)

      try do
        assert :ok = Queue.cast_failure(payload())
      after
        Process.register(pid, Queue)
      end
    end
  end

  describe "cast_failure/2 end-to-end via the supervised Queue" do
    setup do
      # Queue + TaskSupervisor are started by the application. Nothing else
      # to do here — just a placeholder so the describe block has its own
      # scope.
      :ok
    end

    test "auto-applies a create proposal to the wiki", ctx do
      Application.put_env(
        :symphony_elixir,
        :curator_stub_response,
        {:create,
         %{
           "slug" => "auto-applied",
           "title" => "T",
           "topic" => "t",
           "body" => "body\n"
         }}
      )

      :ok = Queue.cast_failure(payload(), project_key: ctx.project_key)
      wait_until(fn -> Wiki.exists?(ctx.project_key, "auto-applied") end)
    end

    test "auto-applies a refine proposal when target exists", ctx do
      seed = %SymphonyElixir.Wiki.Entry{
        slug: "existing",
        title: "Existing",
        topic: "t",
        revision: 1,
        created_at: "2026-04-20T00:00:00Z",
        updated_at: "2026-04-20T00:00:00Z",
        body: "original\n"
      }

      :ok = Wiki.put(ctx.project_key, seed)

      Application.put_env(
        :symphony_elixir,
        :curator_stub_response,
        {:refine, "existing", "refined body\n"}
      )

      :ok = Queue.cast_failure(payload(), project_key: ctx.project_key)

      wait_until(fn ->
        case Wiki.get(ctx.project_key, "existing") do
          {:ok, e} -> e.revision == 2
          _ -> false
        end
      end)
    end

    test "drops a refine proposal when the target is missing", ctx do
      Application.put_env(
        :symphony_elixir,
        :curator_stub_response,
        {:refine, "ghost", "body\n"}
      )

      queue_pid = Process.whereis(Queue)
      :ok = Queue.cast_failure(payload(), project_key: ctx.project_key)

      # learn_from_failure returns {:error, {:refine_target_missing, _}}; the
      # Queue logs and drops. It must stay alive.
      Process.sleep(150)
      assert Process.alive?(queue_pid)
      assert ReviewQueue.list(ctx.project_key) == []
    end

    test "parks a human_review decision", ctx do
      Application.put_env(
        :symphony_elixir,
        :curator_stub_response,
        {:create, %{"slug" => "x", "title" => "T", "topic" => "t", "body" => "b"}}
      )

      Application.put_env(
        :symphony_elixir,
        :curator_stub_critic,
        {:conflict, "other", "contradicts"}
      )

      :ok = Queue.cast_failure(payload(), project_key: ctx.project_key)

      wait_until(fn -> ReviewQueue.list(ctx.project_key) != [] end)
    end

    test "logs and drops :reject proposals", ctx do
      Application.put_env(:symphony_elixir, :curator_stub_response, {:reject, "not useful"})

      :ok = Queue.cast_failure(payload(), project_key: ctx.project_key)

      Process.sleep(100)
      {:ok, summaries} = Wiki.list_summaries(ctx.project_key)
      assert summaries == []
      assert ReviewQueue.list(ctx.project_key) == []
    end

    test "isolates failures — a crashing distiller does not crash the queue", ctx do
      Application.put_env(
        :symphony_elixir,
        :curator_stub_response,
        {:fn, fn _i, _s, _c -> raise "boom" end}
      )

      queue_pid = Process.whereis(Queue)
      assert is_pid(queue_pid)

      capture_log(fn ->
        :ok = Queue.cast_failure(payload(), project_key: ctx.project_key)
        Process.sleep(150)
      end)

      assert Process.alive?(queue_pid)
    end

    test "rescues in-process raises during proposal application", ctx do
      # Return a well-formed :create proposal whose post-sanitize slug is
      # computable, but make Wiki.put fail to trigger the `:ok =` match in
      # handle_proposal. We simulate the failure by swapping in a custom
      # wiki root that becomes read-only mid-test.
      knowledge_root = ctx.knowledge_root
      File.chmod!(knowledge_root, 0o500)

      on_exit(fn -> File.chmod!(knowledge_root, 0o755) end)

      Application.put_env(
        :symphony_elixir,
        :curator_stub_response,
        {:create, %{"slug" => "x", "title" => "T", "topic" => "t", "body" => "b"}}
      )

      queue_pid = Process.whereis(Queue)

      log =
        capture_log(fn ->
          :ok = Queue.cast_failure(payload(), project_key: ctx.project_key)
          Process.sleep(200)
        end)

      assert Process.alive?(queue_pid)
      # Either a match-error was rescued (preferred), or the store returned
      # {:error, _} and a MatchError fired — both paths are rescued.
      assert log =~ "task crashed"
    end

    test "surfaces learn_from_failure errors without crashing", ctx do
      Application.delete_env(:symphony_elixir, :curator_stub_response)

      queue_pid = Process.whereis(Queue)
      :ok = Queue.cast_failure(payload(), project_key: ctx.project_key)

      Process.sleep(100)
      assert Process.alive?(queue_pid)
    end
  end

  describe "default_project_key fallback" do
    setup do
      # Queue + TaskSupervisor are started by the application. Nothing else
      # to do here — just a placeholder so the describe block has its own
      # scope.
      :ok
    end

    test "uses Knowledge.project_key when none is passed in opts", _ctx do
      Application.put_env(:symphony_elixir, :curator_stub_response, {:reject, "noop"})

      queue_pid = Process.whereis(Queue)
      :ok = Queue.cast_failure(payload())

      Process.sleep(100)
      assert Process.alive?(queue_pid)
    end
  end

  describe "ReviewQueue serialization" do
    test "round-trips create proposals", ctx do
      entry = %SymphonyElixir.Wiki.Entry{
        slug: "x",
        title: "T",
        topic: "t",
        revision: 1,
        created_at: "2026-04-20T00:00:00Z",
        updated_at: "2026-04-20T00:00:00Z",
        sources: [%{kind: "verify_log", ref: "r", ingested_at: "2026-04-20T00:00:00Z"}],
        related: [],
        confidence: "medium",
        status: "active",
        body: "body"
      }

      proposal =
        {:create, "x", entry}
        |> wrap_producer()
        |> Proposal.with_final({:human_review, {:create, "x", entry}, {:conflict, "o", "c"}}, {:conflict, "o", "c"})

      :ok = ReviewQueue.park(ctx.project_key, proposal)

      assert [file] = ReviewQueue.list(ctx.project_key)
      assert {:ok, decoded} = ReviewQueue.read(file)

      assert {:human_review, {:create, "x", decoded_entry}, {:conflict, "o", "c"}} =
               decoded.decision

      assert decoded_entry.slug == "x"
      assert decoded_entry.sources == entry.sources

      :ok = ReviewQueue.delete(file)
      assert ReviewQueue.list(ctx.project_key) == []
    end

    test "round-trips refine proposals", ctx do
      proposal =
        {:refine, "slug", "merged"}
        |> wrap_producer()

      :ok = ReviewQueue.park(ctx.project_key, proposal)
      [file] = ReviewQueue.list(ctx.project_key)
      assert {:ok, decoded} = ReviewQueue.read(file)
      assert decoded.decision == {:refine, "slug", "merged"}
    end

    test "round-trips reject proposals", ctx do
      proposal = Proposal.reject("rej")
      :ok = ReviewQueue.park(ctx.project_key, proposal)
      [file] = ReviewQueue.list(ctx.project_key)
      assert {:ok, decoded} = ReviewQueue.read(file)
      assert decoded.decision == :reject
    end

    test "round-trips human_review with refine producer", ctx do
      refine_producer = {:refine, "slug-a", "merged"}

      proposal =
        refine_producer
        |> wrap_producer()
        |> Proposal.with_final(
          {:human_review, refine_producer, {:conflict, "slug-b", "contradicts"}},
          {:conflict, "slug-b", "contradicts"}
        )

      :ok = ReviewQueue.park(ctx.project_key, proposal)
      [file] = ReviewQueue.list(ctx.project_key)
      assert {:ok, decoded} = ReviewQueue.read(file)

      assert {:human_review, {:refine, "slug-a", "merged"}, {:conflict, "slug-b", "contradicts"}} =
               decoded.decision
    end

    test "round-trips :approve verdict", ctx do
      proposal =
        %Proposal{
          decision: :reject,
          producer_decision: :reject,
          critic_verdict: :approve,
          final_decision: :reject,
          rationale: "r",
          source_ref: nil,
          raw_response: nil
        }

      :ok = ReviewQueue.park(ctx.project_key, proposal)
      [file] = ReviewQueue.list(ctx.project_key)
      {:ok, decoded} = ReviewQueue.read(file)
      assert decoded.critic_verdict == :approve
    end

    test "list/1 returns [] when the queue directory does not exist", ctx do
      assert ReviewQueue.list(ctx.project_key <> "-missing") == []
    end

    test "read/1 errors on malformed JSON", ctx do
      dir = ReviewQueue.queue_dir(ctx.project_key)
      File.mkdir_p!(dir)
      bad = Path.join(dir, "bad.json")
      File.write!(bad, "{not json")

      assert {:error, _} = ReviewQueue.read(bad)
    end

    test "decode/1 rejects payloads without a decision", _ctx do
      assert {:error, :invalid_payload} = ReviewQueue.decode(%{"rationale" => "x"})
    end

    test "round-trips a {:reject, reason} critic verdict", ctx do
      proposal = %Proposal{
        decision: :reject,
        producer_decision: :reject,
        critic_verdict: {:reject, "nope"},
        final_decision: :reject,
        rationale: "r",
        source_ref: nil,
        raw_response: nil
      }

      :ok = ReviewQueue.park(ctx.project_key, proposal)
      [file] = ReviewQueue.list(ctx.project_key)
      {:ok, decoded} = ReviewQueue.read(file)
      assert decoded.critic_verdict == {:reject, "nope"}
    end

    test "park/2 returns {:error, _} when the file cannot be written", ctx do
      dir = ReviewQueue.queue_dir(ctx.project_key)
      File.mkdir_p!(dir)
      File.chmod!(dir, 0o500)
      on_exit(fn -> File.chmod!(dir, 0o755) end)

      proposal = Proposal.reject("rej")

      log =
        capture_log(fn ->
          assert {:error, _} = ReviewQueue.park(ctx.project_key, proposal)
        end)

      assert log =~ "could not park proposal"
    end

    test "parks a raw :create proposal (non-human_review) with slug hint", ctx do
      entry = %SymphonyElixir.Wiki.Entry{
        slug: "bare-create",
        title: "T",
        topic: "t",
        revision: 1,
        created_at: "2026-04-20T00:00:00Z",
        updated_at: "2026-04-20T00:00:00Z",
        body: "b"
      }

      proposal = wrap_producer({:create, "bare-create", entry})

      :ok = ReviewQueue.park(ctx.project_key, proposal)
      [file] = ReviewQueue.list(ctx.project_key)
      assert Path.basename(file) =~ "bare-create-"
    end
  end

  defp wrap_producer(decision) do
    %Proposal{
      decision: decision,
      producer_decision: decision,
      critic_verdict: nil,
      final_decision: decision,
      rationale: "r",
      source_ref: "ref",
      raw_response: nil
    }
  end
end
