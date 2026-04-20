defmodule Mix.Tasks.Opal.Review do
  use Mix.Task

  @shortdoc "Drain the curator review queue and adjudicate each parked proposal"

  @moduledoc """
  Replays every parked curator proposal for a project through the interactive
  review CLI and deletes each file once adjudicated.

      mix opal.review
      mix opal.review --project github_apexphere_opal

  Options:
    --project / -p   Project key (defaults to the configured tracker's project_key)
    --dry-run        Print parked files and decisions without prompting or writing

  Parked files that fail to decode are reported and left on disk for manual
  inspection.
  """

  alias SymphonyElixir.Curator.Proposal
  alias SymphonyElixir.Curator.Queue.ReviewQueue
  alias SymphonyElixir.Curator.Review
  alias SymphonyElixir.Knowledge

  @impl Mix.Task
  def run(args) do
    {opts, _positional, invalid} =
      OptionParser.parse(args,
        strict: [project: :string, dry_run: :boolean, help: :boolean],
        aliases: [p: :project, h: :help]
      )

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}")

      true ->
        Mix.Task.run("app.start")
        execute(opts)
    end
  end

  defp execute(opts) do
    project_key = opts[:project] || Knowledge.project_key()
    paths = ReviewQueue.list(project_key)

    if paths == [] do
      Mix.shell().info("No parked proposals for project=#{project_key}")
    else
      Mix.shell().info("Draining #{length(paths)} parked proposal(s) for project=#{project_key}")
      Enum.each(paths, fn path -> process_one(path, project_key, opts) end)
    end
  end

  defp process_one(path, project_key, opts) do
    case ReviewQueue.read(path) do
      {:ok, %Proposal{} = proposal} ->
        if opts[:dry_run] do
          Mix.shell().info("[dry-run] #{Path.basename(path)}: #{summarize(proposal)}")
        else
          adjudicate(proposal, path, project_key)
        end

      {:error, reason} ->
        Mix.shell().error("Could not read #{path}: #{inspect(reason)}")
    end
  end

  defp adjudicate(proposal, path, project_key) do
    Mix.shell().info("\n--- #{Path.basename(path)} ---")

    case Review.run(proposal, project_key) do
      result when result in [:accepted, :rejected, :quit] ->
        :ok = ReviewQueue.delete(path)
        Mix.shell().info("Resolved (#{result}); removed parked file")

      {:error, reason} ->
        Mix.shell().error("Review failed; leaving parked file in place: #{inspect(reason)}")
    end
  end

  defp summarize(%Proposal{decision: :reject}), do: "REJECT"
  defp summarize(%Proposal{decision: {:create, slug, _}}), do: "CREATE #{slug}"
  defp summarize(%Proposal{decision: {:refine, slug, _}}), do: "REFINE #{slug}"

  defp summarize(%Proposal{decision: {:human_review, producer, verdict}}) do
    "HUMAN REVIEW (producer=#{producer_summary(producer)}, verdict=#{verdict_summary(verdict)})"
  end

  defp producer_summary({:create, slug, _}), do: "create #{slug}"
  defp producer_summary({:refine, slug, _}), do: "refine #{slug}"

  defp verdict_summary(:approve), do: "approve"
  defp verdict_summary({:reject, reason}), do: "reject — #{reason}"
  defp verdict_summary({:conflict, slug, reason}), do: "conflict #{slug} — #{reason}"
  defp verdict_summary(nil), do: "(none)"
end
