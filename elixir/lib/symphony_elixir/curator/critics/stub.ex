defmodule SymphonyElixir.Curator.Critics.Stub do
  @moduledoc """
  Critic that returns a recorded verdict instead of calling `claude -p`.

  Used by the curator fixture eval and unit tests so the pipeline runs
  deterministically and doesn't burn LLM credits.

  Configure via `Application.put_env(:symphony_elixir, :curator_stub_critic, response)`
  where `response` is one of:

      :approve
      {:reject, "reason text"}
      {:conflict, "slug", "reason text"}
      {:fn, fn article_body, summaries, candidates, context -> {:ok, verdict} end}
  """

  @behaviour SymphonyElixir.Curator.Critic

  @impl true
  def critique(article_body, summaries, candidates, context) do
    case Application.get_env(:symphony_elixir, :curator_stub_critic) do
      nil ->
        {:error, :stub_critic_not_configured}

      :approve ->
        {:ok, :approve}

      {:reject, reason} ->
        {:ok, {:reject, reason}}

      {:conflict, slug, reason} ->
        {:ok, {:conflict, slug, reason}}

      {:fn, fun} when is_function(fun, 4) ->
        fun.(article_body, summaries, candidates, context)
    end
  end
end
