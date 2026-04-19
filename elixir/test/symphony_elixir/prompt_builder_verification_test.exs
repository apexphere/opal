defmodule SymphonyElixir.PromptBuilderVerificationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue

  @issue %Issue{
    identifier: "MT-900",
    title: "Add /healthz endpoint",
    description: "Return 200 OK",
    state: "Todo",
    url: "https://example.org/issues/MT-900",
    labels: []
  }

  test "appends the verification instruction when verification.enabled is true" do
    write_workflow_file!(Workflow.workflow_file_path(),
      verification_enabled: true,
      prompt: "TASK {{ task.number }}"
    )

    prompt = PromptBuilder.build_prompt(@issue)

    assert prompt =~ "TASK MT-900"
    assert prompt =~ "Verification step (required before declaring done)"
    assert prompt =~ ".opal/verify.json"
    assert prompt =~ "expect_exit"
  end

  test "verification instruction forbids language test runners as recipe steps" do
    write_workflow_file!(Workflow.workflow_file_path(),
      verification_enabled: true,
      prompt: "TASK {{ task.number }}"
    )

    prompt = PromptBuilder.build_prompt(@issue)

    assert prompt =~ "Recipe steps MUST exercise the delivered interface"
    assert prompt =~ "mix test"
    assert prompt =~ "pytest"
    assert prompt =~ "go test"
    assert prompt =~ "npm test"
  end

  test "verification instruction warns that .opal/ is workspace-only" do
    write_workflow_file!(Workflow.workflow_file_path(),
      verification_enabled: true,
      prompt: "TASK {{ task.number }}"
    )

    prompt = PromptBuilder.build_prompt(@issue)

    assert prompt =~ "`.opal/` is workspace-only"
    assert prompt =~ "never commit"
  end

  test "omits the verification instruction when verification.enabled is false" do
    write_workflow_file!(Workflow.workflow_file_path(),
      verification_enabled: false,
      prompt: "TASK {{ task.number }}"
    )

    prompt = PromptBuilder.build_prompt(@issue)

    assert prompt == "TASK MT-900"
    refute prompt =~ "Verification step"
  end

  test "omits the verification instruction by default (verification block absent)" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "TASK {{ task.number }}")

    prompt = PromptBuilder.build_prompt(@issue)

    refute prompt =~ "Verification step"
  end
end
