defmodule SymphonyElixir.Knowledge.Store do
  @moduledoc """
  Storage boundary for Opal's per-project experience knowledge.

  Implementations persist a project's knowledge tree (CLAUDE.md, skills, memory)
  keyed by a stable project slug. The filesystem implementation is the default;
  git-backed, Postgres-backed, and S3-backed backends may plug in later.
  """

  @type project_key :: String.t()
  @type relative_path :: String.t()
  @type tree :: %{files: %{relative_path() => binary()}}

  @callback load(root :: String.t(), project_key()) :: {:ok, tree()} | {:error, term()}
  @callback write(root :: String.t(), project_key(), relative_path(), binary()) ::
              :ok | {:error, term()}
  @callback list_projects(root :: String.t()) :: {:ok, [project_key()]} | {:error, term()}
end
