defmodule SymphonyElixir.Curator.Critics.StubTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Curator.Critics.Stub

  setup do
    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :curator_stub_critic)
    end)

    :ok
  end

  test "errors when no stub verdict is configured" do
    assert {:error, :stub_critic_not_configured} = Stub.critique("body", [], [])
  end

  test "supports :approve atom shorthand" do
    Application.put_env(:symphony_elixir, :curator_stub_critic, :approve)
    assert {:ok, :approve} = Stub.critique("body", [], [])
  end

  test "supports {:reject, reason} tuple" do
    Application.put_env(:symphony_elixir, :curator_stub_critic, {:reject, "one-off observation"})
    assert {:ok, {:reject, "one-off observation"}} = Stub.critique("body", [], [])
  end

  test "supports {:conflict, slug, reason} tuple" do
    Application.put_env(:symphony_elixir, :curator_stub_critic, {:conflict, "alpha", "contradicts existing"})

    assert {:ok, {:conflict, "alpha", "contradicts existing"}} = Stub.critique("body", [], [])
  end

  test "supports {:fn, fun} for inspecting input" do
    Application.put_env(
      :symphony_elixir,
      :curator_stub_critic,
      {:fn,
       fn body, _summaries, _candidates ->
         {:ok, {:reject, "saw body=#{body}"}}
       end}
    )

    assert {:ok, {:reject, "saw body=b"}} = Stub.critique("b", [], [])
  end
end
