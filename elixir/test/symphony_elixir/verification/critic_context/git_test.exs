defmodule SymphonyElixir.Verification.CriticContext.GitTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Verification.CriticContext.Git

  @moduletag :git_integration

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "opal-critic-context-git-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    {_, 0} = System.cmd("git", ["init", "--initial-branch=main"], cd: workspace, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["config", "user.email", "t@example.com"], cd: workspace, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["config", "user.name", "Test"], cd: workspace, stderr_to_stdout: true)

    File.write!(Path.join(workspace, "README.md"), "initial\n")
    {_, 0} = System.cmd("git", ["add", "."], cd: workspace, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["commit", "-m", "initial"], cd: workspace, stderr_to_stdout: true)

    {sha_output, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: workspace, stderr_to_stdout: true)
    base_sha = String.trim(sha_output)

    %{workspace: workspace, base_sha: base_sha}
  end

  test "merge_base/1 returns the branch-point sha of main", %{workspace: workspace, base_sha: base_sha} do
    {_, 0} = System.cmd("git", ["checkout", "-b", "feature"], cd: workspace, stderr_to_stdout: true)
    File.write!(Path.join(workspace, "new.txt"), "hello\n")
    {_, 0} = System.cmd("git", ["add", "."], cd: workspace, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["commit", "-m", "feature"], cd: workspace, stderr_to_stdout: true)

    assert {:ok, returned} = Git.merge_base(workspace)
    assert returned == base_sha
  end

  test "diff/2 returns the unified diff against the base sha", %{workspace: workspace, base_sha: base_sha} do
    {_, 0} = System.cmd("git", ["checkout", "-b", "feature"], cd: workspace, stderr_to_stdout: true)
    File.write!(Path.join(workspace, "new.txt"), "hello\n")
    {_, 0} = System.cmd("git", ["add", "."], cd: workspace, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["commit", "-m", "feature"], cd: workspace, stderr_to_stdout: true)

    assert {:ok, diff} = Git.diff(workspace, base_sha)
    assert diff =~ "new.txt"
    assert diff =~ "+hello"
  end

  test "merge_base/1 falls back to origin/main when local main is missing", %{workspace: workspace} do
    # Rename main → trunk so `merge-base HEAD main` fails on the first try.
    {_, 0} = System.cmd("git", ["branch", "-m", "main", "trunk"], cd: workspace, stderr_to_stdout: true)

    # Fake an origin/main ref by creating a remote-tracking branch against trunk.
    {trunk_sha, 0} = System.cmd("git", ["rev-parse", "trunk"], cd: workspace, stderr_to_stdout: true)
    trunk_sha = String.trim(trunk_sha)

    File.mkdir_p!(Path.join([workspace, ".git", "refs", "remotes", "origin"]))
    File.write!(Path.join([workspace, ".git", "refs", "remotes", "origin", "main"]), trunk_sha)

    assert {:ok, returned} = Git.merge_base(workspace)
    assert returned == trunk_sha
  end

  test "merge_base/1 errors when neither main nor origin/main exist", %{workspace: workspace} do
    {_, 0} = System.cmd("git", ["branch", "-m", "main", "trunk"], cd: workspace, stderr_to_stdout: true)

    assert {:error, {:git_exit, _, _}} = Git.merge_base(workspace)
  end

  test "diff/2 surfaces non-zero exit from git", %{workspace: workspace} do
    assert {:error, {:git_exit, _, _}} = Git.diff(workspace, "notarealref")
  end

  test "shelling out against a non-existent workspace surfaces a :git_exit error" do
    assert {:error, {:git_exit, status, _output}} =
             Git.merge_base("/definitely/not/a/real/path/xyzzy")

    assert status != 0
  end
end
