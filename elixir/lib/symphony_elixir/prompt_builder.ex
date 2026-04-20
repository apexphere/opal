defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from issue data.

  Templates can use either the legacy `issue.X` variable namespace or the
  generic `task.X` namespace (added for tracker-agnostic templates). Both
  point to the same underlying data; `task.number` aliases `issue.identifier`.
  """

  alias SymphonyElixir.{Config, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]

  @verification_instruction """
  ## Verification step (required before declaring done)

  Before you mark this task as complete, write a verification recipe to
  `.opal/verify.json` describing how to exercise the changes you made the way a
  user would. Opal will execute every step and revert the issue to active if
  any step fails.

  Schema (v1):

      {
        "version": "1",
        "description": "<one-line summary of what to exercise>",
        "steps": [
          {
            "name": "<short step label>",
            "shell": "<bash command run from the workspace root>",
            "expect_exit": 0
          }
        ]
      }

  Each step's `shell` runs via `bash -lc` with the workspace as the working
  directory. A step passes when its exit code matches `expect_exit` (default 0).
  Steps run sequentially and stop on the first failure. Pick the smallest set
  of steps that prove the user-visible behaviour you delivered actually works —
  boot the thing, hit it the way a user would, check the response.

  ### Recipe steps MUST exercise the delivered interface, not run unit tests

  A step whose `shell` invokes a language test runner (for example `mix test`,
  `pytest`, `go test`, `npm test`, `cargo test`, `rspec`) is NOT a valid recipe
  step. Unit tests against code you just wrote prove only internal consistency;
  the recipe must prove the change works from the outside. If you delivered an
  HTTP endpoint, the step is a `curl` or equivalent against a running server;
  if you delivered a CLI flag, the step invokes the CLI with that flag; if you
  delivered a module function with no user-facing surface, the step is a short
  `elixir`/`python`/`node` one-liner that calls it and prints an assertion. You
  may still run unit tests separately as a sanity check — just not as the
  recipe.

  ### `.opal/` is workspace-only — never commit it

  Write `.opal/verify.json` (and any other files under `.opal/`) to the
  workspace, but do NOT `git add` them, do NOT stage them, and do NOT let them
  reach the target repository. They are Opal scratch, not project code. If you
  use `git add -A` or `git commit -a`, check the staged list and unstage
  anything under `.opal/` before committing.
  """

  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    template =
      Workflow.current()
      |> prompt_template!()
      |> parse_template!()

    issue_map = issue |> Map.from_struct() |> to_solid_map()
    task_map = Map.put(issue_map, "number", Map.get(issue_map, "identifier"))

    rendered =
      template
      |> Solid.render!(
        %{
          "attempt" => Keyword.get(opts, :attempt),
          "issue" => issue_map,
          "task" => task_map
        },
        @render_opts
      )
      |> IO.iodata_to_binary()

    append_verification_instruction(rendered)
  end

  defp append_verification_instruction(rendered) do
    if Config.settings!().verification.enabled do
      rendered <> "\n\n" <> @verification_instruction
    else
      rendered
    end
  end

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end
end
