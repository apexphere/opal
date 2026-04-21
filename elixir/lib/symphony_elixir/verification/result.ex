defmodule SymphonyElixir.Verification.Result do
  @moduledoc """
  JSON encoding for the verification outcome persisted to
  `<workspace>/.opal/verify-log.json`.
  """

  @spec encode(map()) :: String.t()
  def encode(outcome) when is_map(outcome) do
    outcome
    |> to_payload()
    |> Jason.encode_to_iodata!(pretty: true)
    |> IO.iodata_to_binary()
  end

  defp to_payload(outcome) do
    %{
      "version" => "1",
      "status" => Atom.to_string(outcome.status),
      "started_at" => DateTime.to_iso8601(outcome.started_at),
      "finished_at" => DateTime.to_iso8601(outcome.finished_at),
      "duration_ms" => DateTime.diff(outcome.finished_at, outcome.started_at, :millisecond),
      "skipped_reason" => encode_reason(outcome.skipped_reason),
      "recipe" => encode_recipe(outcome.recipe),
      "rejection" => encode_rejection(Map.get(outcome, :rejection)),
      "steps" => Enum.map(outcome.steps, &encode_step/1)
    }
  end

  defp encode_rejection(nil), do: nil

  defp encode_rejection(%{reason: reason, missing_coverage: missing}) do
    %{"reason" => reason, "missing_coverage" => missing}
  end

  defp encode_step(step) do
    %{
      "name" => step.name,
      "shell" => step.shell,
      "expect_exit" => step.expect_exit,
      "exit" => encode_exit(step.exit),
      "passed" => step.passed,
      "output" => step.output,
      "duration_ms" => step.duration_ms
    }
  end

  defp encode_recipe(nil), do: nil

  defp encode_recipe(%SymphonyElixir.Verification.Recipe{} = recipe) do
    %{
      "description" => recipe.description,
      "step_count" => length(recipe.steps)
    }
  end

  defp encode_exit(:timeout), do: "timeout"
  defp encode_exit(n) when is_integer(n), do: n

  defp encode_reason(nil), do: nil
  defp encode_reason(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp encode_reason(other), do: inspect(other)
end
