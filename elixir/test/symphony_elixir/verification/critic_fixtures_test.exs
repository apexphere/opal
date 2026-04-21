defmodule SymphonyElixir.Verification.CriticFixturesTest do
  @moduledoc """
  Fixture-based regression tests for `SymphonyElixir.Verification.Critic`.

  Three on-disk bundles under `test/fixtures/verification/critic/` cover:

    * `reject_trivial_recipe/` — unit-tests-only recipe that the critic
      must reject.
    * `approve_user_perspective_recipe/` — recipe that exercises the
      behaviour through its runtime surface; critic should approve.
    * `dogfood_branch_enforcement/` — replays the exact task + diff +
      recipe from the #43 dogfood where agent-29 shipped a compile+test
      verify recipe for the branch-before-edit feature. This is the
      runnable proof from #42.

  Each bundle has four files:

      task.md
      diff.patch
      recipe.json
      expected.json  (verdict + reason_contains + missing_coverage_contains)

  The default `@tag :fixture` tests load all four files and assert that
  `Critic.build_prompt/3` embeds them verbatim — cheap, offline, and
  catches prompt-shape regressions.

  The verdict-level claims in `expected.json` are asserted only when
  `@tag :live_critic` is included, which shells out to the real `codex`
  runtime. That path is reserved for manual dogfood runs and is not
  exercised in CI.
  """

  use ExUnit.Case, async: true

  alias SymphonyElixir.Verification.Critic

  @fixtures_root Path.expand("../../fixtures/verification/critic", __DIR__)

  defp bundles do
    @fixtures_root
    |> File.ls!()
    |> Enum.filter(&File.dir?(Path.join(@fixtures_root, &1)))
    |> Enum.sort()
  end

  defp load_bundle(name) do
    dir = Path.join(@fixtures_root, name)
    task = File.read!(Path.join(dir, "task.md"))
    diff = File.read!(Path.join(dir, "diff.patch"))
    recipe = File.read!(Path.join(dir, "recipe.json"))
    expected = dir |> Path.join("expected.json") |> File.read!() |> Jason.decode!()
    %{name: name, dir: dir, task: task, diff: diff, recipe: recipe, expected: expected}
  end

  describe "fixture bundle layout" do
    test "every bundle carries the four required files" do
      for name <- bundles() do
        dir = Path.join(@fixtures_root, name)

        for required <- ~w(task.md diff.patch recipe.json expected.json) do
          path = Path.join(dir, required)
          assert File.exists?(path), "fixture bundle #{name} is missing #{required}"
        end
      end
    end

    test "expected.json verdicts are approve or reject" do
      for name <- bundles() do
        %{expected: expected} = load_bundle(name)

        assert expected["verdict"] in ~w(approve reject),
               "fixture #{name} has invalid verdict #{inspect(expected["verdict"])}"

        assert is_binary(expected["reason_contains"])
        assert is_binary(expected["missing_coverage_contains"])
      end
    end

    test "at least the three planned bundles exist" do
      names = bundles()
      assert "reject_trivial_recipe" in names
      assert "approve_user_perspective_recipe" in names
      assert "dogfood_branch_enforcement" in names
    end
  end

  describe "prompt construction" do
    @describetag :fixture

    for bundle_name <- File.ls!(@fixtures_root),
        File.dir?(Path.join(@fixtures_root, bundle_name)) do
      @bundle_name bundle_name

      test "#{@bundle_name}: build_prompt embeds task, diff, and recipe verbatim" do
        bundle = load_bundle(@bundle_name)
        prompt = Critic.build_prompt(bundle.task, bundle.diff, bundle.recipe)

        assert String.contains?(prompt, bundle.task),
               "prompt for #{bundle.name} must include the task description verbatim"

        assert String.contains?(prompt, bundle.diff),
               "prompt for #{bundle.name} must include the diff verbatim"

        assert String.contains?(prompt, bundle.recipe),
               "prompt for #{bundle.name} must include the recipe verbatim"

        assert String.contains?(prompt, "<untrusted_input>"),
               "prompt must sandbox diff + recipe inside <untrusted_input> fences"
      end
    end
  end

  describe "live critic verdict (manual dogfood only)" do
    @describetag :live_critic

    for bundle_name <- File.ls!(@fixtures_root),
        File.dir?(Path.join(@fixtures_root, bundle_name)) do
      @bundle_name bundle_name

      test "#{@bundle_name}: real codex critic matches expected verdict" do
        bundle = load_bundle(@bundle_name)

        case Critic.critique(bundle.task, bundle.diff, bundle.recipe) do
          {:ok, :approve} ->
            assert bundle.expected["verdict"] == "approve",
                   "#{bundle.name}: expected reject, got approve"

          {:ok, {:reject, detail}} ->
            assert bundle.expected["verdict"] == "reject",
                   "#{bundle.name}: expected approve, got reject (#{detail.reason})"

            reason_needle = bundle.expected["reason_contains"]

            if reason_needle != "" do
              assert String.contains?(String.downcase(detail.reason), String.downcase(reason_needle)),
                     "#{bundle.name}: reason #{inspect(detail.reason)} missing #{inspect(reason_needle)}"
            end

            missing_needle = bundle.expected["missing_coverage_contains"]

            if missing_needle != "" do
              assert String.contains?(
                       String.downcase(detail.missing_coverage),
                       String.downcase(missing_needle)
                     ),
                     "#{bundle.name}: missing_coverage #{inspect(detail.missing_coverage)} missing #{inspect(missing_needle)}"
            end

          {:error, reason} ->
            flunk("#{bundle.name}: live critic errored: #{inspect(reason)}")
        end
      end
    end
  end
end
