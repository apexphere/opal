defmodule SymphonyElixir.Knowledge.Store.Filesystem do
  @moduledoc """
  Filesystem-backed `SymphonyElixir.Knowledge.Store`.

  Layout per project: `<root>/<project_key>/CLAUDE.md + skills/ + memory/`.
  """

  @behaviour SymphonyElixir.Knowledge.Store

  @impl true
  @spec load(String.t(), String.t()) :: {:ok, SymphonyElixir.Knowledge.Store.tree()}
  def load(root, project_key) when is_binary(root) and is_binary(project_key) do
    project_dir = Path.join(root, project_key)

    case File.dir?(project_dir) do
      true -> {:ok, %{files: collect_files(project_dir)}}
      false -> {:ok, %{files: %{}}}
    end
  end

  @impl true
  @spec write(String.t(), String.t(), String.t(), binary()) :: :ok | {:error, term()}
  def write(root, project_key, relative_path, content)
      when is_binary(root) and is_binary(project_key) and is_binary(relative_path) and
             is_binary(content) do
    with :ok <- validate_relative_path(relative_path) do
      target = Path.join([root, project_key, relative_path])
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, content)
      :ok
    end
  end

  @impl true
  @spec list_projects(String.t()) :: {:ok, [String.t()]}
  def list_projects(root) when is_binary(root) do
    case File.ls(root) do
      {:ok, entries} ->
        projects =
          entries
          |> Enum.filter(&File.dir?(Path.join(root, &1)))
          |> Enum.sort()

        {:ok, projects}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_files(project_dir) do
    project_dir
    |> list_all_files()
    |> Enum.reduce(%{}, fn absolute_path, acc ->
      relative = Path.relative_to(absolute_path, project_dir)
      Map.put(acc, relative, File.read!(absolute_path))
    end)
  end

  defp list_all_files(dir) do
    dir
    |> File.ls!()
    |> Enum.flat_map(fn entry ->
      full = Path.join(dir, entry)

      case File.dir?(full) do
        true -> list_all_files(full)
        false -> [full]
      end
    end)
  end

  defp validate_relative_path(path) do
    cond do
      String.starts_with?(path, "/") ->
        {:error, {:unsafe_relative_path, path}}

      String.contains?(path, "..") ->
        {:error, {:unsafe_relative_path, path}}

      true ->
        :ok
    end
  end
end
