defmodule SymphonyElixir.Critic.FallbackTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.Critic.Fallback

  describe "quota_exhausted?/1" do
    test "matches the canonical Codex usage-limit banner" do
      stdout = """
      OpenAI Codex v0.113.0
      session id: 019db24c-e61f-7c23-bdec-796189a50711
      ERROR: You've hit your usage limit. Upgrade to Pro (https://chatgpt.com/explore/pro), visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at 2:06 PM.
      """

      assert Fallback.quota_exhausted?(stdout)
    end

    test "is case-insensitive" do
      assert Fallback.quota_exhausted?("YOU'VE HIT YOUR USAGE LIMIT")
      assert Fallback.quota_exhausted?("Upgrade to Pro today")
      assert Fallback.quota_exhausted?("Please purchase more credits")
    end

    test "returns false for unrelated stdout" do
      refute Fallback.quota_exhausted?("")
      refute Fallback.quota_exhausted?("codex ran fine")
      refute Fallback.quota_exhausted?("error: connection refused")
    end

    test "returns false for non-binary input" do
      refute Fallback.quota_exhausted?(nil)
      refute Fallback.quota_exhausted?(:atom)
      refute Fallback.quota_exhausted?(42)
    end
  end

  describe "run_with_cc_fallback/2" do
    test "returns the Codex result on :ok without invoking Claude" do
      parent = self()

      codex = fn -> {:ok, "codex-output"} end
      claude = fn -> send(parent, :claude_called) end

      assert {:ok, "codex-output"} = Fallback.run_with_cc_fallback(codex, claude)
      refute_received :claude_called
    end

    test "passes through non-rate-limit errors without invoking Claude" do
      parent = self()

      codex = fn -> {:error, {:codex_exit, 7, "boom"}} end
      claude = fn -> send(parent, :claude_called) end

      assert {:error, {:codex_exit, 7, "boom"}} =
               Fallback.run_with_cc_fallback(codex, claude)

      refute_received :claude_called
    end

    test "invokes Claude when Codex returns :rate_limited and surfaces that result" do
      codex = fn -> {:error, :rate_limited} end
      claude = fn -> {:ok, "claude-output"} end

      log =
        capture_log(fn ->
          assert {:ok, "claude-output"} = Fallback.run_with_cc_fallback(codex, claude)
        end)

      assert log =~ "falling back to Claude Code"
    end

    test "surfaces Claude errors on the fallback path" do
      codex = fn -> {:error, :rate_limited} end
      claude = fn -> {:error, {:claude_exit, 1, "nope"}} end

      capture_log(fn ->
        assert {:error, {:claude_exit, 1, "nope"}} =
                 Fallback.run_with_cc_fallback(codex, claude)
      end)
    end
  end
end
