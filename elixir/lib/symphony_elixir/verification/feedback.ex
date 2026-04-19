defmodule SymphonyElixir.Verification.Feedback do
  @moduledoc """
  Render a continuation-prompt block from `<workspace>/.opal/verify-log.json`
  when the previous verification run failed. The block is fed back into the
  next agent turn so the agent sees the prior failure and diagnoses it instead
  of blindly retrying. Non-fail outcomes, missing logs, and corrupt logs all
  collapse to `:none` (corruption is logged so the operator notices).
  """

  require Logger

  alias SymphonyElixir.Verification

  @output_tail_limit 4 * 1024

  @spec render(Path.t() | nil) :: {:ok, String.t()} | :none
  def render(nil), do: :none

  def render(workspace) when is_binary(workspace) do
    path = Path.join(workspace, Verification.log_rel_path())

    with {:ok, content} <- read_log(path),
         {:ok, data} <- decode_log(content, path) do
      render_from_payload(data)
    end
  end

  defp read_log(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> :none
    end
  end

  defp decode_log(content, path) do
    case Jason.decode(content) do
      {:ok, data} ->
        {:ok, data}

      {:error, reason} ->
        Logger.warning("Verification feedback skipped: corrupt log path=#{path} reason=#{inspect(reason)}")
        :none
    end
  end

  defp render_from_payload(%{"status" => "fail"} = data) do
    {:ok, build_block(data)}
  end

  defp render_from_payload(_other), do: :none

  defp build_block(%{"steps" => [_ | _] = steps} = _data) do
    step = Enum.find(steps, fn s -> Map.get(s, "passed") == false end)

    """
    ## Previous verification failed

    Opal ran your `.opal/verify.json` after the last turn and it did not pass.
    Diagnose the root cause below before making another attempt; do not simply
    re-run the same steps.

    - Failed step: #{Map.fetch!(step, "name")}
    - Command: `#{Map.fetch!(step, "shell")}`
    - Expected exit: #{Map.fetch!(step, "expect_exit")} | Actual exit: #{Map.fetch!(step, "exit")}
    - Duration: #{Map.fetch!(step, "duration_ms")}ms

    Captured output (tail):

    ```
    #{truncate_output(Map.fetch!(step, "output"))}
    ```

    Full log: `.opal/verify-log.json`.
    """
  end

  defp build_block(%{"steps" => []} = data) do
    """
    ## Previous verification failed

    Opal ran your `.opal/verify.json` after the last turn and it did not pass.
    Diagnose the root cause below before making another attempt; do not simply
    re-run the same steps.

    The recipe could not be executed: #{Map.fetch!(data, "skipped_reason")}.

    Full log: `.opal/verify-log.json`.
    """
  end

  defp truncate_output(output) when is_binary(output) do
    size = byte_size(output)

    if size > @output_tail_limit do
      omitted = size - @output_tail_limit
      tail = binary_part(output, size - @output_tail_limit, @output_tail_limit)
      "... (output truncated, #{omitted} bytes omitted; see .opal/verify-log.json) ...\n" <> tail
    else
      output
    end
  end
end
