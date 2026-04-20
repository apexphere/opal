defmodule Mix.Tasks.Opal.Learn do
  use Mix.Task

  @shortdoc "Distill a single article into a wiki proposal and review it"

  @moduledoc """
  Runs one curator cycle from the command line.

      mix opal.learn path/to/article.md
      mix opal.learn path/to/article.md --project github_apexphere_opal
      mix opal.learn path/to/article.md --source-ref feeds/react.md

  Options:
    --project / -p   Project key (defaults to the configured tracker's project_key)
    --source-ref     Source ref recorded on the entry (defaults to the article path)
    --auto-accept    Skip the review prompt and write immediately on create/refine
                     (intended for fixture evaluation, NOT for production use)
  """

  alias SymphonyElixir.Curator
  alias SymphonyElixir.Curator.Review
  alias SymphonyElixir.Knowledge

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [project: :string, source_ref: :string, help: :boolean, auto_accept: :boolean],
        aliases: [p: :project, h: :help]
      )

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}")

      positional == [] ->
        Mix.raise("Usage: mix opal.learn <article-path> [--project KEY] [--source-ref REF]")

      true ->
        Mix.Task.run("app.start")
        execute(positional, opts)
    end
  end

  defp execute([article_path | _], opts) do
    project_key = opts[:project] || Knowledge.project_key()
    source_ref = opts[:source_ref] || article_path

    case Curator.learn(article_path, project_key: project_key, source_ref: source_ref) do
      {:ok, proposal} ->
        Mix.shell().info(format_decision(proposal))

        if opts[:auto_accept] do
          auto_apply(proposal, project_key)
        else
          Review.run(proposal, project_key)
        end

      {:error, reason} ->
        Mix.shell().error("Curator failed: #{inspect(reason)}")
    end
  end

  defp format_decision(%{decision: :reject, rationale: r}), do: "REJECT: #{r}"
  defp format_decision(%{decision: {:create, slug, _entry}, rationale: r}), do: "CREATE #{slug}: #{r}"
  defp format_decision(%{decision: {:refine, slug, _body}, rationale: r}), do: "REFINE #{slug}: #{r}"

  defp format_decision(%{decision: {:human_review, _producer, _verdict}, rationale: r}) do
    "HUMAN REVIEW: #{r}"
  end

  defp auto_apply(proposal, project_key) do
    case proposal.decision do
      :reject ->
        Mix.shell().info("(auto-accept) reject -> no write")

      _ ->
        Review.run(proposal, project_key, input_fun: fn _prompt -> "a" end)
    end
  end
end
