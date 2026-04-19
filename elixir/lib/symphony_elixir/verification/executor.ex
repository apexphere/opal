defmodule SymphonyElixir.Verification.Executor do
  @moduledoc """
  Behaviour for executing a single verification step inside a workspace.

  The default implementation is `SymphonyElixir.Verification.Executor.Bash`,
  which runs the step's `shell` via `bash -lc` with the workspace as cwd.
  """

  alias SymphonyElixir.Verification.Recipe.Step

  @type result :: %{
          exit: integer() | :timeout,
          output: String.t(),
          duration_ms: non_neg_integer()
        }

  @callback run_step(step :: Step.t(), workspace :: Path.t(), opts :: keyword()) ::
              result()
end
