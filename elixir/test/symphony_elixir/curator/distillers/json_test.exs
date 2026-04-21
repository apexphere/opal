defmodule SymphonyElixir.Curator.Distillers.JsonTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Curator.Distillers.Json

  describe "parse_output/1" do
    test "parses a :reject response" do
      raw = """
      prefix

      ```json
      {"decision": "reject", "rationale": "off topic"}
      ```
      """

      assert {:ok, proposal} = Json.parse_output(raw)
      assert proposal.decision == :reject
      assert proposal.rationale == "off topic"
    end

    test "parses a :create response into an Entry" do
      raw = """
      ```json
      {
        "decision": "create",
        "slug": "react-hooks",
        "title": "React Hooks",
        "topic": "react",
        "body": "# heading\\n\\nbody",
        "rationale": "novel"
      }
      ```
      """

      assert {:ok, proposal} = Json.parse_output(raw)
      assert {:create, "react-hooks", entry} = proposal.decision
      assert entry.title == "React Hooks"
      assert entry.body =~ "heading"
      assert entry.perfect_for == []
      assert entry.not_ideal_for == []
    end

    test "propagates perfect_for / not_ideal_for on :create" do
      raw = """
      ```json
      {
        "decision": "create",
        "slug": "x",
        "title": "T",
        "topic": "t",
        "body": "b",
        "perfect_for": ["case a", "  case b  ", ""],
        "not_ideal_for": ["anti a"]
      }
      ```
      """

      assert {:ok, proposal} = Json.parse_output(raw)
      assert {:create, "x", entry} = proposal.decision
      assert entry.perfect_for == ["case a", "case b"]
      assert entry.not_ideal_for == ["anti a"]
    end

    test "coerces non-string items in perfect_for on :create" do
      raw = """
      ```json
      {
        "decision": "create",
        "slug": "x",
        "title": "T",
        "topic": "t",
        "body": "b",
        "perfect_for": [123, true, "ok"]
      }
      ```
      """

      assert {:ok, proposal} = Json.parse_output(raw)
      assert {:create, "x", entry} = proposal.decision
      assert entry.perfect_for == ["123", "true", "ok"]
    end

    test "tolerates non-list perfect_for on :create" do
      raw = """
      ```json
      {
        "decision": "create",
        "slug": "x",
        "title": "T",
        "topic": "t",
        "body": "b",
        "perfect_for": "not a list"
      }
      ```
      """

      assert {:ok, proposal} = Json.parse_output(raw)
      assert {:create, "x", entry} = proposal.decision
      assert entry.perfect_for == []
    end

    test "parses a :refine response" do
      raw = """
      ```json
      {"decision": "refine", "target_slug": "auth", "merged_body": "merged", "rationale": "dup"}
      ```
      """

      assert {:ok, proposal} = Json.parse_output(raw)
      assert {:refine, "auth", "merged"} = proposal.decision
    end

    test "errors on missing JSON fence" do
      assert {:error, :missing_json_fence} = Json.parse_output("no fence here")
    end

    test "errors on invalid JSON inside the fence" do
      raw = """
      ```json
      not actually json
      ```
      """

      assert {:error, %Jason.DecodeError{}} = Json.parse_output(raw)
    end

    test "errors on unknown decision value" do
      raw = """
      ```json
      {"decision": "shrug"}
      ```
      """

      assert {:error, {:unknown_decision, "shrug"}} = Json.parse_output(raw)
    end

    test "defaults rationale when create payload omits it" do
      raw = """
      ```json
      {"decision": "create", "slug": "x", "title": "T", "topic": "t", "body": "b"}
      ```
      """

      assert {:ok, proposal} = Json.parse_output(raw)
      assert proposal.rationale == "created"
    end

    test "defaults rationale when refine payload omits it" do
      raw = """
      ```json
      {"decision": "refine", "target_slug": "x", "merged_body": "m"}
      ```
      """

      assert {:ok, proposal} = Json.parse_output(raw)
      assert proposal.rationale == "refined"
    end

    test "defaults rationale when reject payload omits it" do
      raw = """
      ```json
      {"decision": "reject"}
      ```
      """

      assert {:ok, proposal} = Json.parse_output(raw)
      assert proposal.rationale == "rejected"
    end
  end
end
