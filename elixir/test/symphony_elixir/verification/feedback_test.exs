defmodule SymphonyElixir.Verification.FeedbackTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.Verification.Feedback

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "opal-feedback-ws-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)
    %{workspace: workspace}
  end

  test "returns :none when workspace is nil" do
    assert Feedback.render(nil) == :none
  end

  test "returns :none when the log file is missing", %{workspace: workspace} do
    assert Feedback.render(workspace) == :none
  end

  test "returns :none when status is pass", %{workspace: workspace} do
    write_log!(workspace, %{"status" => "pass", "steps" => []})

    assert Feedback.render(workspace) == :none
  end

  test "returns :none when status is skipped", %{workspace: workspace} do
    write_log!(workspace, %{"status" => "skipped", "steps" => [], "skipped_reason" => "no_recipe"})

    assert Feedback.render(workspace) == :none
  end

  test "returns :none and logs a warning when the log is corrupt", %{workspace: workspace} do
    write_log_raw!(workspace, "{not json")

    log =
      capture_log(fn ->
        assert Feedback.render(workspace) == :none
      end)

    assert log =~ "Verification feedback skipped: corrupt log"
  end

  test "renders a failure block with step details", %{workspace: workspace} do
    write_log!(workspace, %{
      "status" => "fail",
      "steps" => [
        %{
          "name" => "curl healthz",
          "shell" => "curl -fsS http://localhost:4000/healthz",
          "expect_exit" => 0,
          "exit" => 7,
          "passed" => false,
          "output" => "connection refused",
          "duration_ms" => 42
        }
      ]
    })

    assert {:ok, block} = Feedback.render(workspace)
    assert block =~ "## Previous verification failed"
    assert block =~ "Failed step: curl healthz"
    assert block =~ "Command: `curl -fsS http://localhost:4000/healthz`"
    assert block =~ "Expected exit: 0 | Actual exit: 7"
    assert block =~ "Duration: 42ms"
    assert block =~ "connection refused"
    refute block =~ "output truncated"
  end

  test "renders a recipe-invalid block when steps list is empty", %{workspace: workspace} do
    write_log!(workspace, %{
      "status" => "fail",
      "steps" => [],
      "skipped_reason" => "no_recipe"
    })

    assert {:ok, block} = Feedback.render(workspace)
    assert block =~ "The recipe could not be executed: no_recipe."
    refute block =~ "Failed step:"
    refute block =~ "Captured output"
  end

  test "renders a failure block when actual exit is the timeout string", %{workspace: workspace} do
    write_log!(workspace, %{
      "status" => "fail",
      "steps" => [
        %{
          "name" => "boot server",
          "shell" => "mix phx.server",
          "expect_exit" => 0,
          "exit" => "timeout",
          "passed" => false,
          "output" => "still booting...",
          "duration_ms" => 60_000
        }
      ]
    })

    assert {:ok, block} = Feedback.render(workspace)
    assert block =~ "Actual exit: timeout"
  end

  test "truncates output that exceeds 4 KB and reports the omitted bytes", %{workspace: workspace} do
    output = String.duplicate("x", 5000)
    omitted = 5000 - 4 * 1024

    write_log!(workspace, %{
      "status" => "fail",
      "steps" => [
        %{
          "name" => "noisy step",
          "shell" => "./noisy",
          "expect_exit" => 0,
          "exit" => 1,
          "passed" => false,
          "output" => output,
          "duration_ms" => 10
        }
      ]
    })

    assert {:ok, block} = Feedback.render(workspace)
    assert block =~ "... (output truncated, #{omitted} bytes omitted; see .opal/verify-log.json) ..."

    captured = extract_captured_output(block)
    assert byte_size(captured) <= 4 * 1024
  end

  defp write_log!(workspace, payload) do
    write_log_raw!(workspace, Jason.encode!(payload))
  end

  defp write_log_raw!(workspace, content) do
    opal_dir = Path.join(workspace, ".opal")
    File.mkdir_p!(opal_dir)
    File.write!(Path.join(opal_dir, "verify-log.json"), content)
  end

  defp extract_captured_output(block) do
    [_, after_open] = String.split(block, "Captured output (tail):\n\n```\n", parts: 2)
    [captured, _] = String.split(after_open, "\n```\n", parts: 2)

    case String.split(captured, "\n", parts: 2) do
      ["... (output truncated" <> _, rest] -> rest
      [single] -> single
    end
  end
end
