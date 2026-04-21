defmodule SymphonyElixir.Verification.CriticSchema do
  @moduledoc """
  Loader for the verify-path critic output JSON schema shipped in
  `priv/verification/`.

  Used by critics that invoke LLM CLIs supporting structured-output
  schemas (e.g. `codex exec --output-schema`). The schema is stored as a
  real JSON file (not inlined per-call) so it can be passed to the CLI
  directly.

  Codex's schema validator requires every property to appear in
  `required`, even optional ones (optional fields use an empty-string
  sentinel rather than null). That quirk is baked into the on-disk
  schema; callers just copy it.
  """

  @schema_path Application.app_dir(:symphony_elixir, "priv/verification/critic_schema.json")

  @doc """
  Absolute path to the critic schema file inside the application `priv`
  directory. Guaranteed to exist at runtime.
  """
  @spec path() :: Path.t()
  def path, do: @schema_path

  @doc """
  Reads the raw schema JSON as a string. Useful for tests that want to
  round-trip the schema text or copy it elsewhere.
  """
  @spec read!() :: String.t()
  def read!, do: File.read!(@schema_path)
end
