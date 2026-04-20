defmodule SymphonyElixir.Curator.Queue do
  @moduledoc """
  Cast-only GenServer that turns verification failures into curator cycles
  without blocking the orchestrator.

  On `cast_failure/1`, it spawns a `Task.Supervisor` child (`:temporary`) that
  calls `Curator.learn_from_failure/2` and routes the resulting proposal:

    * `:reject`             — log and drop.
    * `approve`-shaped      — auto-apply the producer proposal.
    * `:human_review`       — park the proposal as JSON in the project's
                              review queue for `mix opal.review`.

  `max_concurrency: 1` so one failure is processed at a time; subsequent
  casts are buffered in the GenServer mailbox.

  Failures inside the spawned task never crash the queue — exceptions are
  caught and logged. The orchestrator never awaits this process.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.Curator
  alias SymphonyElixir.Curator.{Proposal, Queue.ReviewQueue}
  alias SymphonyElixir.Wiki
  alias SymphonyElixir.Wiki.Entry

  @task_supervisor SymphonyElixir.Curator.TaskSupervisor

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Asynchronously enqueue a failed verification for distillation.

  `payload` matches `Curator.failure_payload/0`. Accepts a keyword `opts`
  passed through to `learn_from_failure/2` (tests use this to inject stubs).

  Safe to call from anywhere — wraps `Process.whereis` so a missing queue
  (e.g. during boot or in unit tests) does not raise.
  """
  @spec cast_failure(map(), keyword()) :: :ok
  def cast_failure(payload, opts \\ []) when is_map(payload) do
    case Process.whereis(__MODULE__) do
      nil ->
        Logger.debug("Curator.Queue not running; dropping verify-log failure payload")
        :ok

      pid when is_pid(pid) ->
        GenServer.cast(pid, {:failure, payload, opts})
    end
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:failure, payload, opts}, state) do
    spawn_task(payload, opts)
    {:noreply, state}
  end

  defp spawn_task(payload, opts) do
    project_key = opts[:project_key] || default_project_key()
    fun = fn -> safely_run(payload, Keyword.put(opts, :project_key, project_key)) end
    {:ok, _pid} = Task.Supervisor.start_child(@task_supervisor, fun, restart: :temporary)
    :ok
  end

  defp safely_run(payload, opts) do
    case Curator.learn_from_failure(payload, opts) do
      {:ok, proposal} ->
        handle_proposal(proposal, opts[:project_key])

      {:error, reason} ->
        Logger.warning("Curator.Queue learn_from_failure error=#{inspect(reason)}")
    end
  rescue
    error ->
      Logger.warning("Curator.Queue task crashed: #{Exception.message(error)}")
  end

  defp handle_proposal(%Proposal{decision: :reject} = proposal, _project_key) do
    Logger.info("Curator.Queue rejected verify-log failure rationale=#{proposal.rationale}")
  end

  defp handle_proposal(%Proposal{decision: {:create, slug, %Entry{} = entry}}, project_key) do
    :ok = Wiki.put(project_key, entry)
    Logger.info("Curator.Queue auto-applied create slug=#{slug} project=#{project_key}")
  end

  defp handle_proposal(%Proposal{decision: {:refine, slug, merged_body}}, project_key) do
    {:ok, %Entry{} = current} = Wiki.get(project_key, slug)

    updated = %Entry{
      current
      | revision: current.revision + 1,
        updated_at: iso8601_now(),
        body: merged_body
    }

    :ok = Wiki.put(project_key, updated)
    Logger.info("Curator.Queue auto-applied refine slug=#{slug} project=#{project_key}")
  end

  defp handle_proposal(
         %Proposal{decision: {:human_review, _producer, _verdict}} = proposal,
         project_key
       ) do
    ReviewQueue.park(project_key, proposal)
  end

  defp default_project_key do
    SymphonyElixir.Knowledge.project_key()
  end

  defp iso8601_now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
