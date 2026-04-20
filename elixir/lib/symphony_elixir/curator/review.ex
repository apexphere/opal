defmodule SymphonyElixir.Curator.Review do
  @moduledoc """
  Human-in-the-loop review CLI for a curator `Proposal`.

  Renders a unified diff between the current wiki entry (if any) and what the
  proposal would write, then prompts:

      [a]ccept / [r]eject / [e]dit-then-accept / [q]uit

  On accept (`a` or `e` after edit), calls `Wiki.put/2`. On reject/quit,
  no wiki write happens.

  The IO module is injected so this is unit-testable; production uses the
  default `IO`.
  """

  alias SymphonyElixir.Curator.Proposal
  alias SymphonyElixir.Wiki
  alias SymphonyElixir.Wiki.Entry

  @type io_module :: module()

  @type opts :: [
          io: io_module(),
          input_fun: (String.t() -> String.t()),
          editor_fun: (String.t() -> String.t())
        ]

  @doc """
  Runs the review flow for `proposal` against the wiki for `project_key`.
  Returns `:accepted | :rejected | :quit | {:error, reason}`.
  """
  @spec run(Proposal.t(), String.t(), opts()) ::
          :accepted | :rejected | :quit | {:error, term()}
  def run(%Proposal{} = proposal, project_key, opts \\ []) do
    io = Keyword.get(opts, :io, IO)
    input_fun = Keyword.get(opts, :input_fun, &default_gets/1)
    editor_fun = Keyword.get(opts, :editor_fun, &identity/1)

    render_proposal(io, proposal, project_key)

    case proposal.decision do
      :reject ->
        :rejected

      _ ->
        prompt_loop(io, input_fun, editor_fun, proposal, project_key)
    end
  end

  @doc """
  Renders a unified diff between `before_text` and `after_text`. Both inputs
  are split on `\\n` and labeled `--- a/<label>` / `+++ b/<label>`.

  This is a hand-rolled line-by-line diff (insert/delete only); it is not a
  full Myers diff but is sufficient for showing wiki entry deltas at the
  review prompt.
  """
  @spec unified_diff(String.t(), String.t(), String.t()) :: String.t()
  def unified_diff(before_text, after_text, label \\ "wiki-entry") do
    before_lines = String.split(before_text, "\n")
    after_lines = String.split(after_text, "\n")

    body = diff_lines(before_lines, after_lines)
    "--- a/#{label}\n+++ b/#{label}\n" <> body
  end

  defp diff_lines(before_lines, after_lines) do
    before_set = MapSet.new(before_lines)
    after_set = MapSet.new(after_lines)

    deletions = Enum.filter(before_lines, &(not MapSet.member?(after_set, &1)))
    additions = Enum.filter(after_lines, &(not MapSet.member?(before_set, &1)))

    Enum.map_join(deletions, "\n", &"-#{&1}") <>
      maybe_newline(deletions) <>
      Enum.map_join(additions, "\n", &"+#{&1}") <>
      maybe_newline(additions)
  end

  defp maybe_newline([]), do: ""
  defp maybe_newline(_), do: "\n"

  defp render_proposal(io, %Proposal{decision: :reject} = proposal, _project_key) do
    io.puts("Curator decision: REJECT")
    io.puts("Rationale: #{proposal.rationale}")
  end

  defp render_proposal(io, %Proposal{decision: {:create, slug, %Entry{} = entry}} = proposal, project_key) do
    io.puts("Curator decision: CREATE")
    io.puts("Project: #{project_key}")
    io.puts("New entry slug: #{slug}")
    io.puts("Title: #{entry.title}")
    io.puts("Topic: #{entry.topic}")
    io.puts("Rationale: #{proposal.rationale}")
    io.puts("")
    io.puts(unified_diff("", Entry.serialize(entry), "wiki/#{slug}.md"))
  end

  defp render_proposal(io, %Proposal{decision: {:refine, slug, merged_body}} = proposal, project_key) do
    io.puts("Curator decision: REFINE")
    io.puts("Project: #{project_key}")
    io.puts("Target slug: #{slug}")
    io.puts("Rationale: #{proposal.rationale}")
    io.puts("")

    case Wiki.get(project_key, slug) do
      {:ok, current} ->
        io.puts(unified_diff(current.body, merged_body, "wiki/#{slug}.md"))

      {:error, reason} ->
        io.puts("(Could not read current entry: #{inspect(reason)})")
        io.puts(unified_diff("", merged_body, "wiki/#{slug}.md"))
    end
  end

  defp prompt_loop(io, input_fun, editor_fun, proposal, project_key) do
    io.puts("")
    answer = input_fun.("[a]ccept / [r]eject / [e]dit-then-accept / [q]uit > ")

    case String.trim(String.downcase(answer)) do
      "a" -> apply_proposal(io, proposal, project_key)
      "y" -> apply_proposal(io, proposal, project_key)
      "r" -> :rejected
      "n" -> :rejected
      "q" -> :quit
      "e" -> apply_with_edit(io, editor_fun, proposal, project_key)
      _ -> prompt_loop(io, input_fun, editor_fun, proposal, project_key)
    end
  end

  defp apply_proposal(io, %Proposal{decision: {:create, _slug, %Entry{} = entry}}, project_key) do
    case Wiki.put(project_key, entry) do
      :ok ->
        io.puts("Accepted. Wrote wiki/#{entry.slug}.md")
        :accepted

      {:error, reason} = error ->
        io.puts("Failed to write entry: #{inspect(reason)}")
        error
    end
  end

  defp apply_proposal(io, %Proposal{decision: {:refine, slug, merged_body}}, project_key) do
    case Wiki.get(project_key, slug) do
      {:ok, %Entry{} = current} ->
        updated = %{
          current
          | revision: current.revision + 1,
            updated_at: iso8601_now(),
            body: merged_body
        }

        :ok = Wiki.put(project_key, updated)
        io.puts("Accepted. Refined wiki/#{slug}.md (revision #{updated.revision})")
        :accepted

      {:error, reason} = error ->
        io.puts("Cannot refine missing entry #{slug}: #{inspect(reason)}")
        error
    end
  end

  defp apply_with_edit(io, editor_fun, proposal, project_key) do
    edited_proposal = edit_proposal(editor_fun, proposal)
    apply_proposal(io, edited_proposal, project_key)
  end

  defp edit_proposal(editor_fun, %Proposal{decision: {:create, slug, %Entry{} = entry}} = proposal) do
    new_body = editor_fun.(entry.body)
    %Proposal{proposal | decision: {:create, slug, %{entry | body: new_body}}}
  end

  defp edit_proposal(editor_fun, %Proposal{decision: {:refine, slug, body}} = proposal) do
    new_body = editor_fun.(body)
    %Proposal{proposal | decision: {:refine, slug, new_body}}
  end

  defp default_gets(prompt), do: IO.gets(prompt) || ""
  defp identity(value), do: value

  defp iso8601_now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
