defmodule SymphonyElixir.PromptBuilderFeedbackTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue

  @issue %Issue{
    identifier: "MT-901",
    title: "Add /healthz endpoint",
    description: "Return 200 OK",
    state: "Todo",
    url: "https://example.org/issues/MT-901",
    labels: []
  }

  defp fail_log do
    Jason.encode!(%{
      "version" => "1",
      "status" => "fail",
      "steps" => [
        %{
          "name" => "curl-healthz",
          "shell" => "curl -fsS http://localhost:4000/healthz",
          "expect_exit" => 0,
          "exit" => 7,
          "passed" => false,
          "output" => "curl: (7) connection refused",
          "duration_ms" => 12
        }
      ]
    })
  end

  defp stage_log!(workspace, content) do
    File.mkdir_p!(Path.join(workspace, ".opal"))
    File.write!(Path.join([workspace, ".opal", "verify-log.json"]), content)
  end

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "opal-prompt-fb-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)
    %{workspace: workspace}
  end

  test "omits the feedback block when verification.enabled is true but no workspace is given",
       %{workspace: workspace} do
    write_workflow_file!(Workflow.workflow_file_path(),
      verification_enabled: true,
      prompt: "TASK {{ task.number }}"
    )

    stage_log!(workspace, fail_log())

    prompt = PromptBuilder.build_prompt(@issue)

    refute prompt =~ "Previous verification failed"
  end

  test "appends the feedback block after the recipe instruction when a prior run failed",
       %{workspace: workspace} do
    write_workflow_file!(Workflow.workflow_file_path(),
      verification_enabled: true,
      prompt: "TASK {{ task.number }}"
    )

    stage_log!(workspace, fail_log())

    prompt = PromptBuilder.build_prompt(@issue, workspace: workspace)

    assert prompt =~ "TASK MT-901"

    instruction_index = :binary.match(prompt, "Verification step (required before declaring done)") |> elem(0)
    feedback_index = :binary.match(prompt, "Previous verification failed") |> elem(0)
    assert feedback_index > instruction_index

    assert prompt =~ "curl-healthz"
    assert prompt =~ "curl: (7) connection refused"
  end

  test "omits the feedback block when verification.enabled is false, even with a fail log",
       %{workspace: workspace} do
    write_workflow_file!(Workflow.workflow_file_path(),
      verification_enabled: false,
      prompt: "TASK {{ task.number }}"
    )

    stage_log!(workspace, fail_log())

    prompt = PromptBuilder.build_prompt(@issue, workspace: workspace)

    assert prompt == "TASK MT-901"
    refute prompt =~ "Previous verification failed"
  end
end
