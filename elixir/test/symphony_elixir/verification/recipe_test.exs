defmodule SymphonyElixir.Verification.RecipeTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Verification.Recipe
  alias SymphonyElixir.Verification.Recipe.Step

  test "rel_path points at .opal/verify.json" do
    assert Recipe.rel_path() == ".opal/verify.json"
  end

  describe "parse/1" do
    test "parses a single-step recipe with defaults" do
      json =
        Jason.encode!(%{
          "version" => "1",
          "description" => "Curl new endpoint",
          "steps" => [%{"name" => "ping", "shell" => "curl -fsS http://localhost:4000"}]
        })

      assert {:ok, %Recipe{description: "Curl new endpoint", steps: [step]}} = Recipe.parse(json)
      assert %Step{name: "ping", shell: "curl -fsS http://localhost:4000", expect_exit: 0} = step
    end

    test "parses multiple steps and respects expect_exit" do
      json =
        Jason.encode!(%{
          "steps" => [
            %{"name" => "first", "shell" => "true"},
            %{"name" => "second", "shell" => "false", "expect_exit" => 1}
          ]
        })

      assert {:ok, %Recipe{steps: [first, second]}} = Recipe.parse(json)
      assert %Step{name: "first", expect_exit: 0} = first
      assert %Step{name: "second", expect_exit: 1} = second
    end

    test "synthesizes a step name when missing" do
      json = Jason.encode!(%{"steps" => [%{"shell" => "true"}]})
      assert {:ok, %Recipe{steps: [%Step{name: "step_1"}]}} = Recipe.parse(json)
    end

    test "rejects malformed JSON" do
      assert {:error, {:invalid_recipe, {:malformed_json, _}}} = Recipe.parse("not json")
    end

    test "rejects non-object payloads" do
      assert {:error, {:invalid_recipe, :not_an_object}} = Recipe.parse(Jason.encode!([1, 2, 3]))
    end

    test "rejects missing steps" do
      assert {:error, {:invalid_recipe, :missing_steps}} = Recipe.parse(Jason.encode!(%{}))
    end

    test "rejects empty steps" do
      assert {:error, {:invalid_recipe, :empty_steps}} =
               Recipe.parse(Jason.encode!(%{"steps" => []}))
    end

    test "rejects step missing shell" do
      assert {:error, {:invalid_recipe, {:step, 1, :missing_shell}}} =
               Recipe.parse(Jason.encode!(%{"steps" => [%{"name" => "x"}]}))
    end

    test "rejects non-object step entries" do
      assert {:error, {:invalid_recipe, {:step, 1, :not_an_object}}} =
               Recipe.parse(Jason.encode!(%{"steps" => [42]}))
    end

    test "rejects steps that are not a list" do
      assert {:error, {:invalid_recipe, :steps_not_a_list}} =
               Recipe.parse(Jason.encode!(%{"steps" => "nope"}))
    end

    test "falls back to expect_exit 0 when value is not an integer" do
      json = Jason.encode!(%{"steps" => [%{"shell" => "true", "expect_exit" => "boom"}]})
      assert {:ok, %Recipe{steps: [%Step{expect_exit: 0}]}} = Recipe.parse(json)
    end
  end

  describe "read/1" do
    setup do
      workspace =
        Path.join(System.tmp_dir!(), "opal-recipe-ws-#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace)
      on_exit(fn -> File.rm_rf(workspace) end)
      %{workspace: workspace}
    end

    test "returns :no_recipe when the file is absent", %{workspace: workspace} do
      assert {:error, :no_recipe} = Recipe.read(workspace)
    end

    test "loads a recipe from .opal/verify.json", %{workspace: workspace} do
      File.mkdir_p!(Path.join(workspace, ".opal"))

      File.write!(
        Path.join(workspace, ".opal/verify.json"),
        Jason.encode!(%{"steps" => [%{"name" => "ping", "shell" => "true"}]})
      )

      assert {:ok, %Recipe{steps: [%Step{name: "ping"}]}} = Recipe.read(workspace)
    end

    test "surfaces non-enoent read errors as invalid_recipe", %{workspace: workspace} do
      File.write!(Path.join(workspace, ".opal"), "")

      assert {:error, {:invalid_recipe, {:read_failed, _}}} = Recipe.read(workspace)
    end
  end
end
