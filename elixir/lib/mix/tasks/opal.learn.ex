defmodule Mix.Tasks.Opal.Learn do
  use Mix.Task

  @shortdoc "Distill a single article into a wiki proposal and review it"

  @moduledoc """
  Runs one curator cycle from the command line.

      mix opal.learn path/to/article.md
      mix opal.learn path/to/article.md --project github_apexphere_opal
      mix opal.learn path/to/article.md --source-ref feeds/react.md
      mix opal.learn path/to/article.md --project-description "Stock and crypto technical analysis"

  Options:
    --project / -p         Project key (defaults to the configured tracker's project_key)
    --project-description  Free-text domain context for the project (e.g.
                           "Stock and crypto technical analysis"). Threaded
                           into the distiller + critic prompts so the LLM
                           judges relevance against the project domain
                           rather than Opal-the-tool. Defaults to the
                           `:curator_project_description` config value.
    --source-ref           Source ref recorded on the entry (defaults to the article path)
    --auto-accept          Skip the review prompt and write immediately on create/refine
                           (intended for fixture evaluation, NOT for production use)
    --critic-runtime       Which critic backend to use: `claude` (default) or `codex`.
                           Overrides the `:curator_critic_module` config for this
                           invocation only. Use `codex` to get a second-opinion critic
                           backed by a different model provider than the producer.
  """

  alias SymphonyElixir.Curator
  alias SymphonyElixir.Curator.Review
  alias SymphonyElixir.Knowledge

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          project: :string,
          project_description: :string,
          source_ref: :string,
          help: :boolean,
          auto_accept: :boolean,
          critic_runtime: :string
        ],
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
    project_description = opts[:project_description] || Knowledge.project_description()
    source_ref = opts[:source_ref] || article_path

    learn_opts =
      [project_key: project_key, source_ref: source_ref]
      |> maybe_put(:project_description, project_description)
      |> maybe_put(:critic, resolve_critic_flag(opts[:critic_runtime]))

    case Curator.learn(article_path, learn_opts) do
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

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp resolve_critic_flag(nil), do: nil
  defp resolve_critic_flag("claude"), do: Curator.resolve_critic(:claude)
  defp resolve_critic_flag("codex"), do: Curator.resolve_critic(:codex)

  defp resolve_critic_flag(other) do
    Mix.raise("Invalid --critic-runtime value #{inspect(other)}; expected claude|codex")
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
