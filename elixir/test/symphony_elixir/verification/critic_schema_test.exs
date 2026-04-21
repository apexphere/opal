defmodule SymphonyElixir.Verification.CriticSchemaTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Verification.CriticSchema

  test "path/0 points at an existing JSON file in priv" do
    path = CriticSchema.path()
    assert File.exists?(path)
    assert Path.extname(path) == ".json"
  end

  test "read!/0 returns valid JSON matching the critic verdict contract" do
    raw = CriticSchema.read!()
    parsed = Jason.decode!(raw)

    assert parsed["type"] == "object"
    assert parsed["additionalProperties"] == false

    # Codex quirk: every property must appear in required, even optional.
    assert Enum.sort(parsed["required"]) == ["missing_coverage", "reason", "verdict"]

    assert parsed["properties"]["verdict"]["enum"] == ["approve", "reject"]
    assert parsed["properties"]["missing_coverage"]["type"] == "string"
  end
end
