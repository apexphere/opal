defmodule SymphonyElixir.Curator.Distillers.StubTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Curator.Distillers.Stub
  alias SymphonyElixir.Curator.Proposal

  setup do
    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :curator_stub_response)
    end)

    :ok
  end

  defp input do
    %{body: "b", source_ref: "ref.md", ingested_at: "2026-04-20T00:00:00Z"}
  end

  test "errors when no stub response is configured" do
    assert {:error, :stub_response_not_configured} = Stub.distill(input(), [], [])
  end

  test "supports :reject atom shorthand" do
    Application.put_env(:symphony_elixir, :curator_stub_response, :reject)
    assert {:ok, %{decision: :reject}} = Stub.distill(input(), [], [])
  end

  test "supports {:reject, rationale} tuple" do
    Application.put_env(:symphony_elixir, :curator_stub_response, {:reject, "spam"})
    assert {:ok, %{decision: :reject, rationale: "spam"}} = Stub.distill(input(), [], [])
  end

  test "supports {:create, attrs} tuple" do
    Application.put_env(:symphony_elixir, :curator_stub_response, {:create, %{"slug" => "foo", "title" => "Foo", "topic" => "t", "body" => "b"}})

    assert {:ok, %{decision: {:create, "foo", entry}}} = Stub.distill(input(), [], [])
    assert entry.title == "Foo"
  end

  test "supports {:refine, slug, body} tuple" do
    Application.put_env(:symphony_elixir, :curator_stub_response, {:refine, "alpha", "merged"})

    assert {:ok, %{decision: {:refine, "alpha", "merged"}}} = Stub.distill(input(), [], [])
  end

  test "supports {:fn, fun} for inspecting input" do
    Application.put_env(
      :symphony_elixir,
      :curator_stub_response,
      {:fn,
       fn input, _summaries, _candidates ->
         {:ok, Proposal.reject("saw body=#{input.body}")}
       end}
    )

    assert {:ok, %{rationale: "saw body=b"}} = Stub.distill(input(), [], [])
  end
end
